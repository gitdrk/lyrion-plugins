package Plugins::WeatherAlerts::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Time::HiRes;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::WeatherAlerts::Audio;
use Plugins::WeatherAlerts::Events;
use Plugins::WeatherAlerts::Feed;
use Plugins::WeatherAlerts::Policy;
use Plugins::WeatherAlerts::Takeover;
use Plugins::WeatherAlerts::Wyoming;

if ( main::WEBUI ) {
	require Plugins::WeatherAlerts::Settings;
}

use constant DISPLAY_SECONDS  => 30;
use constant HEALTH_SECONDS   => 60;
use constant FEED_STALE       => 600;
use constant FEED_WARN_EVERY  => 1800;
use constant SEEN_RETENTION   => 86400;
use constant RECOVERY_DELAY   => 10;

my $prefs = preferences('plugin.weatheralerts');

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.weatheralerts',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_WEATHERALERTS',
});

$prefs->init({
	zones        => '',
	pollSeconds  => 60,
	alertVolume  => 70,
	testVolume   => 25,
	speechServer => '',
	voice        => 'en_US-lessac-medium',
	quietEnabled => 0,
	quietStart   => '22:00',
	quietEnd     => '07:00',
	seen         => {},
	map { ('level_' . $_->{code} => $_->{level}) } Plugins::WeatherAlerts::Events::EVENTS,
});

$prefs->setValidate({ validator => 'intlimit', low => 30, high => 3600 }, 'pollSeconds');
$prefs->setValidate({ validator => 'intlimit', low => 1,  high => 100 }, qw(alertVolume testVolume));

# The 1.0 setting held only an HTTP Piper address.
$prefs->migrate(2, sub {
	my $old = $prefs->get('piperUrl');
	$prefs->set('speechServer', $old) if $old && !$prefs->get('speechServer');
	$prefs->set('piperUrl', '');
	1;
});

my @held;
my $lastFeedWarning = 0;
my @voices;

sub voices { return @voices }

# Refreshes the voice list shown in settings. Only Wyoming servers can list voices.
sub refreshVoices {
	my ($host, $port) = Plugins::WeatherAlerts::Wyoming->parseServer($prefs->get('speechServer'));

	if (!$host) {
		@voices = ();
		return;
	}

	Plugins::WeatherAlerts::Wyoming->describe(host => $host, port => $port, done => sub {
		my ($info, $error) = @_;
		@voices = $info ? Plugins::WeatherAlerts::Wyoming->voiceNames($info, 'en_') : ();
		$log->warn("Could not list speech voices: $error") if !$info;
	});
}

sub getDisplayName {
	return 'PLUGIN_WEATHERALERTS';
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin();

	if ( main::WEBUI ) {
		Plugins::WeatherAlerts::Settings->new;
	}

	Slim::Control::Request::addDispatch(['weatheralerts', 'test'],     [0, 0, 1, \&_testCommand]);
	Slim::Control::Request::addDispatch(['weatheralerts', 'simulate'], [0, 0, 1, \&_simulateCommand]);
	Slim::Control::Request::addDispatch(['weatheralerts', 'stop'],     [0, 0, 0, \&_stopCommand]);
	Slim::Control::Request::addDispatch(['weatheralerts', 'status'],   [0, 1, 0, \&_statusQuery]);

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + RECOVERY_DELAY, sub {
		Plugins::WeatherAlerts::Takeover->recover;
		Plugins::WeatherAlerts::Feed->start(\&onAlerts);
	});

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + HEALTH_SECONDS, \&_health);

	refreshVoices();
	$prefs->setChange(\&refreshVoices, 'speechServer');

	$log->info('Started, zones: ' . ($prefs->get('zones') || 'not set'));
}

sub shutdownPlugin {
	Plugins::WeatherAlerts::Feed->stop;
	Plugins::WeatherAlerts::Takeover->shutdown;
	Slim::Utils::Timers::killTimers(undef, \&_health);
}

sub levels {
	return { map { $_->{code} => $prefs->get('level_' . $_->{code}) } Plugins::WeatherAlerts::Events::EVENTS };
}

sub eligible {
	my ($class, $client) = @_;

	return 0 if !$client->isPlayer || $client->model eq 'group';
	return 0 if ($client->modelName || '') =~ /Bridge/;
	return 1;
}

sub enabled {
	my ($class, $client) = @_;

	my $choice = $prefs->client($client)->get('enabled');

	return defined $choice ? $choice : $class->eligible($client);
}

sub alertVolume {
	my ($class, $client) = @_;

	return $prefs->client($client)->get('alertVolume') || $prefs->get('alertVolume');
}

sub players {
	my ($class) = @_;

	return grep { $class->enabled($_) } Slim::Player::Client::clients();
}

sub _quiet {
	return 0 if !$prefs->get('quietEnabled');

	my ($hour, $minute) = (localtime)[2, 1];
	my $P = 'Plugins::WeatherAlerts::Policy';

	return $P->inQuietHours($hour * 60 + $minute, $P->minutesOfDay($prefs->get('quietStart')), $P->minutesOfDay($prefs->get('quietEnd')));
}

sub _remember {
	my ($alert, $seen) = @_;

	$seen->{ $alert->{id} } = {
		time  => time,
		ends  => $alert->{ends},
		zones => $alert->{zones},
	};
}

sub _prune {
	my ($seen) = @_;

	for my $id (keys %$seen) {
		my $record = $seen->{$id};
		delete $seen->{$id} if ($record->{ends} || $record->{time}) + SEEN_RETENTION < time;
	}
}

sub onAlerts {
	my ($alerts) = @_;

	my $seen = $prefs->get('seen') || {};
	my $levels = levels();
	my $quiet = _quiet();
	my $changed;

	for my $alert (@$alerts) {
		my $action = Plugins::WeatherAlerts::Policy->decide(
			alert => $alert, levels => $levels, seen => $seen, now => time, quiet => $quiet,
		);

		next if $action eq 'ignore' && !$alert->{id};

		if ($action ne 'ignore') {
			$log->info("$alert->{event} ($alert->{id}): $action");
			push @held, $alert if $action eq 'hold';
			act($action, $alert) if $action ne 'hold';
		}

		if (!$seen->{ $alert->{id} }) {
			_remember($alert, $seen);
			$changed = 1;
		}
	}

	_prune($seen);
	$prefs->set('seen', $seen) if $changed;

	_releaseHeld() if !$quiet;
}

sub _releaseHeld {
	my $levels = levels();

	while (my $alert = shift @held) {
		next if $alert->{expires} && $alert->{expires} <= time;
		act($levels->{ $alert->{code} } || 'display', $alert);
	}
}

sub _lines {
	my ($alert) = @_;

	return [ $alert->{event}, Plugins::WeatherAlerts::Policy->clean($alert->{headline}) || $alert->{area} ];
}

# Args after the level and alert: clients, and volume to replace the alert volume.
sub act {
	my ($level, $alert, %args) = @_;

	my @clients = $args{clients} ? @{ $args{clients} } : __PACKAGE__->players;

	return if $level eq 'off' || !@clients;

	if ($level eq 'display') {
		Plugins::WeatherAlerts::Takeover->show(\@clients, _lines($alert), DISPLAY_SECONDS);
		return;
	}

	@clients = grep { $_->power } @clients if $level eq 'announce';
	return if !@clients;

	Plugins::WeatherAlerts::Audio->build(alert => $alert, level => $level, done => sub {
		my $audio = shift;

		if (!$audio) {
			# Without audio, the screens are the only warning left.
			Plugins::WeatherAlerts::Takeover->show(\@clients, _lines($alert), DISPLAY_SECONDS);
			return;
		}

		Plugins::WeatherAlerts::Takeover->start(
			clients  => \@clients,
			url      => $audio->{url},
			duration => $audio->{duration},
			title    => $alert->{event},
			lines    => _lines($alert),
			volume   => sub { $args{volume} || __PACKAGE__->alertVolume(shift) },
		);
	});
}

sub testAlert {
	my ($class, %args) = @_;

	my $name = $args{name} || 'Required Weekly Test';

	return {
		source   => 'test',
		id       => 'test-' . time,
		event    => $name,
		code     => $args{code} || 'TEST',
		headline => "This is a test of the NOAA Weather Alerts plugin. $name. No action is needed.",
		area     => '',
		fips     => [],
		ends     => time + 900,
	};
}

sub _requestedClients {
	my ($request) = @_;

	my $ids = $request->getParam('player');

	return [ __PACKAGE__->players ] if !$ids;

	return [ grep { $_ } map { Slim::Player::Client::getClient($_) } split(/,/, $ids) ];
}

sub runTest {
	my ($class, %args) = @_;

	act('interrupt', $class->testAlert, clients => $args{clients}, volume => $prefs->get('testVolume'));
}

sub _testCommand {
	my $request = shift;

	__PACKAGE__->runTest(clients => _requestedClients($request));
	$request->setStatusDone;
}

# Plays an alert as if it arrived, at the test volume, without marking anything as seen.
sub _simulateCommand {
	my $request = shift;

	my $code = uc($request->getParam('code') || 'TOR');
	my ($event) = grep { $_->{code} eq $code } Plugins::WeatherAlerts::Events::EVENTS;

	if (!$event) {
		$request->setStatusBadParams;
		return;
	}

	my $level = $request->getParam('level') || levels()->{$code};
	my $alert = __PACKAGE__->testAlert(name => $event->{name}, code => $code);

	act($level, $alert, clients => _requestedClients($request), volume => $prefs->get('testVolume'));

	$request->setStatusDone;
}

sub _stopCommand {
	my $request = shift;

	Plugins::WeatherAlerts::Takeover->stopAll;
	$request->setStatusDone;
}

sub _statusQuery {
	my $request = shift;

	my $status = Plugins::WeatherAlerts::Feed->status;

	$request->addResult('lastSuccess', $status->{lastSuccess});
	$request->addResult('lastError', $status->{lastError});
	$request->addResult('activeAlerts', $status->{active});
	$request->addResult('takeover', Plugins::WeatherAlerts::Takeover->isActive);
	$request->addResult('held', scalar @held);
	$request->addResult('players', join(',', map { $_->name } __PACKAGE__->players));
	$request->setStatusDone;
}

sub feedStale {
	my ($class) = @_;

	return 0 if !Plugins::WeatherAlerts::Feed->zones;

	my $last = Plugins::WeatherAlerts::Feed->status->{lastSuccess};

	return time - $last > FEED_STALE;
}

sub _health {
	_releaseHeld() if @held && !_quiet();

	if (__PACKAGE__->feedStale && time - $lastFeedWarning > FEED_WARN_EVERY) {
		$lastFeedWarning = time;
		$log->warn('Weather alerts are not being received');
		Plugins::WeatherAlerts::Takeover->show([ __PACKAGE__->players ], [ 'Weather alerts offline', 'Check NOAA Weather Alerts settings' ], DISPLAY_SECONDS);
	}

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + HEALTH_SECONDS, \&_health);
}

1;
