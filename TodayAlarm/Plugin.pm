package Plugins::TodayAlarm::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use File::Spec::Functions qw(catfile);
use Time::HiRes;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Utils::Alarm;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::TodayAlarm::Player;
use Plugins::TodayAlarm::Script;
use Plugins::TodayAlarm::Sound;
use Plugins::TodayAlarm::Sources;
use Plugins::TodayAlarm::Wyoming;

if ( main::WEBUI ) {
	require Plugins::TodayAlarm::Settings;
}

use constant REFRESH_EVERY => 1800;
use constant FIRST_REFRESH => 15;
use constant DECIDE_DELAY  => 0.4;
use constant BRIEF_DELAY   => 2.5;
use constant RECENT        => 5;
use constant REPEAT_DELAY  => 1.5;
use constant FILE_AGE      => 86400;
use constant CHIME_FILE    => 'morning-chime-1.wav';

my $prefs = preferences('plugin.todayalarm');

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.todayalarm',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_TODAYALARM',
});

$prefs->init({
	google         => [],
	outlook        => [],
	icloud         => [],
	feeds          => [],
	perFeed        => 2,
	totalHeadlines => 5,
	freshHours     => 24,
	sayFeedNames   => 1,
	maxEvents      => 8,
	briefingVolume => 40,
	briefOnPower   => 0,
	briefOnTimeout => 0,
	speechServer   => '',
	voice          => 'en_US-lessac-medium',
});

$prefs->setValidate({ validator => 'intlimit', low => 1, high => 10 },  qw(perFeed totalHeadlines));
$prefs->setValidate({ validator => 'intlimit', low => 1, high => 168 }, 'freshHours');
$prefs->setValidate({ validator => 'intlimit', low => 1, high => 30 },  'maxEvents');
$prefs->setValidate({ validator => 'intlimit', low => 1, high => 100 }, 'briefingVolume');

my (%lastCommand, %timedOut, %savedRepeat, @voices, $chimeUrl, $serial);

sub getDisplayName { 'PLUGIN_TODAYALARM' }

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin();

	if ( main::WEBUI ) {
		Plugins::TodayAlarm::Settings->new;
	}

	if ($chimeUrl = _chime()) {
		Slim::Utils::Alarm->addPlaylists('PLUGIN_TODAYALARM', [ { title => '{PLUGIN_TODAYALARM_CHIME}', url => $chimeUrl } ]);
	}

	Slim::Control::Request::subscribe(\&_command, [['pause', 'stop', 'power']]);
	Slim::Control::Request::subscribe(\&_alarm, [['alarm'], ['sound', 'end', '_cmd']]);

	Slim::Control::Request::addDispatch(['todayalarm', 'brief'],   [0, 0, 1, \&_briefCommand]);
	Slim::Control::Request::addDispatch(['todayalarm', 'refresh'], [0, 0, 0, \&_refreshCommand]);
	Slim::Control::Request::addDispatch(['todayalarm', 'status'],  [0, 1, 0, \&_statusQuery]);

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + FIRST_REFRESH, \&_scheduledRefresh);

	refreshVoices();
	$prefs->setChange(\&refreshVoices, 'speechServer');
	$prefs->setChange(sub { Plugins::TodayAlarm::Sources->refresh }, qw(google outlook icloud feeds));
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_command);
	Slim::Control::Request::unsubscribe(\&_alarm);
	Slim::Utils::Timers::killTimers(undef, \&_scheduledRefresh);
}

sub _scheduledRefresh {
	Plugins::TodayAlarm::Sources->refresh;
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + REFRESH_EVERY, \&_scheduledRefresh);
}

sub chimeUrl { return $chimeUrl }

# The alarm sound is generated once into the cache folder.
sub _chime {
	my $file = catfile(Plugins::TodayAlarm::Sources->cacheDir, CHIME_FILE);

	if (!-s $file) {
		my $S = 'Plugins::TodayAlarm::Sound';
		if (open(my $fh, '>:raw', $file)) {
			print $fh $S->wav($S->morningChime);
			close($fh);
		}
		else {
			$log->error("Could not write the alarm chime: $!");
			return;
		}
	}

	return Slim::Utils::Misc::fileURLFromPath($file);
}

sub voices { return @voices }

sub refreshVoices {
	my ($host, $port) = Plugins::TodayAlarm::Wyoming->parseServer($prefs->get('speechServer'));

	if (!$host) {
		@voices = ();
		return;
	}

	Plugins::TodayAlarm::Wyoming->describe(host => $host, port => $port, done => sub {
		my ($info, $error) = @_;
		@voices = $info ? Plugins::TodayAlarm::Wyoming->voiceNames($info, 'en_') : ();
		$log->warn("Could not list speech voices: $error") if !$info;
	});
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

# Remembers the last stop, pause or power on each player, to tell how an alarm ended.
sub _command {
	my $request = shift;

	my $client = $request->client or return;

	$lastCommand{ $client->id } = {
		command => $request->getRequest(0),
		source  => $request->source || '',
		time    => Time::HiRes::time(),
	};
}

sub _alarm {
	my $request = shift;

	my $client = $request->client or return;
	my $event = $request->getRequest(1) || '';
	my $id = $client->id;

	if ($event eq 'sound') {
		# The alarm ID is a named parameter on this notification.
		my $alarm = Slim::Utils::Alarm->getAlarm($client, $request->getParam('_id')) || $client->alarmData->{currentAlarm};

		# The chime is short, so it repeats until the alarm ends.
		if ($alarm && $chimeUrl && ($alarm->playlist || '') eq $chimeUrl) {
			$savedRepeat{$id} = Slim::Player::Playlist::repeat($client) || 0;
			$client->execute(['playlist', 'repeat', 1]);
		}
	}
	elsif ($event eq '_cmd') {
		$timedOut{$id} = Time::HiRes::time();
	}
	elsif ($event eq 'end') {
		if (defined(my $repeat = delete $savedRepeat{$id})) {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + REPEAT_DELAY, sub { $client->execute(['playlist', 'repeat', $repeat]) });
		}

		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + DECIDE_DELAY, \&_decide);
	}
}

sub _decide {
	my ($client) = @_;

	my $id = $client->id;
	my $now = Time::HiRes::time();
	my $last = $lastCommand{$id};
	my $recent = $last && $now - $last->{time} < RECENT;
	my $timedOut = ($timedOut{$id} && $now - $timedOut{$id} < RECENT) || ($recent && $last->{source} eq 'ALARM');

	if (!__PACKAGE__->enabled($client)) {
		return;
	}

	if ($timedOut && !$prefs->get('briefOnTimeout')) {
		return $log->info('Alarm timed out on ' . $client->name . ', so no briefing');
	}

	if (!$timedOut && $recent && $last->{command} eq 'power' && !$prefs->get('briefOnPower')) {
		return $log->info('Alarm ended with the power button on ' . $client->name . ', so no briefing');
	}

	# Lyrion restores the player's power and volume a second after the alarm ends.
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + BRIEF_DELAY, sub { __PACKAGE__->brief(shift) });
}

sub _prune {
	my $dir = Plugins::TodayAlarm::Sources->cacheDir;

	for my $file (glob(catfile($dir, 'briefing-*.wav'))) {
		unlink($file) if time - (stat($file))[9] > FILE_AGE;
	}
}

sub _speak {
	my ($text, $done) = @_;

	my ($host, $port) = Plugins::TodayAlarm::Wyoming->parseServer($prefs->get('speechServer'));

	return $done->() if !$host;

	Plugins::TodayAlarm::Wyoming->synthesize(host => $host, port => $port, voice => $prefs->get('voice'), text => $text, done => sub {
		my ($wav, $error) = @_;
		my $pcm = Plugins::TodayAlarm::Sound->readWav($wav);
		$log->warn('Speech server failed: ' . ($error || 'unreadable audio') . '. The briefing will be on screen only.') if !defined $pcm;
		$done->($pcm);
	});
}

sub script {
	my ($class, $now) = @_;

	my ($events, $problems, $stale) = Plugins::TodayAlarm::Sources->today($now);

	return Plugins::TodayAlarm::Script->compose(
		now          => $now || time,
		events       => $events,
		problems     => $problems,
		stale        => $stale,
		headlines    => [ Plugins::TodayAlarm::Sources->headlines($now) ],
		hasCalendars => scalar(Plugins::TodayAlarm::Sources->calendars),
		maxEvents    => $prefs->get('maxEvents'),
		sayFeedNames => $prefs->get('sayFeedNames'),
	);
}

sub brief {
	my ($class, $client) = @_;

	return if !$client || Plugins::TodayAlarm::Player->isPlaying($client);

	my $script = $class->script;
	my $S = 'Plugins::TodayAlarm::Sound';

	_speak($script->{text}, sub {
		my ($speech) = @_;

		my $pcm = $S->chime . $S->silence(0.4) . (defined $speech ? $speech . $S->silence(0.6) : '');

		_prune();
		my $file = catfile(Plugins::TodayAlarm::Sources->cacheDir, sprintf('briefing-%d-%d.wav', time, ++$serial));

		if (!open(my $fh, '>:raw', $file)) {
			return $log->error("Could not write the briefing: $!");
		}
		else {
			print $fh $S->wav($pcm);
			close($fh);
		}

		Plugins::TodayAlarm::Player->play($client,
			url      => Slim::Utils::Misc::fileURLFromPath($file),
			duration => $S->duration($pcm) + (defined $speech ? 0 : 4 * @{ $script->{screens} }),
			screens  => $script->{screens},
			volume   => $prefs->get('briefingVolume'),
		);
	});
}

sub _briefCommand {
	my $request = shift;

	my @clients = grep { $_ } map { Slim::Player::Client::getClient($_) } split(/,/, $request->getParam('player') || '');

	if (!@clients) {
		$request->setStatusBadParams;
		return;
	}

	__PACKAGE__->brief($_) for @clients;
	$request->setStatusDone;
}

sub _refreshCommand {
	my $request = shift;

	Plugins::TodayAlarm::Sources->refresh;
	$request->setStatusDone;
}

sub _statusQuery {
	my $request = shift;

	my @rows = Plugins::TodayAlarm::Sources->status;

	$request->addResult('calendars', scalar grep { $_->{kind} eq 'Calendar' } @rows);
	$request->addResult('calendarsOk', scalar grep { $_->{kind} eq 'Calendar' && $_->{ok} } @rows);
	$request->addResult('feeds', scalar grep { $_->{kind} eq 'Feed' } @rows);
	$request->addResult('feedsOk', scalar grep { $_->{kind} eq 'Feed' && $_->{ok} } @rows);
	$request->addResult('lastRefresh', Plugins::TodayAlarm::Sources->lastRefresh);
	$request->addResult('speech', Plugins::TodayAlarm::Wyoming->parseServer($prefs->get('speechServer')) ? 1 : 0);
	$request->addResult('voices', scalar @voices);
	$request->addResult('chime', $chimeUrl ? 1 : 0);
	$request->addResult('players', join(',', map { $_->name } grep { __PACKAGE__->enabled($_) } Slim::Player::Client::clients()));
	$request->addResult('preview', __PACKAGE__->script->{text});
	$request->setStatusDone;
}

1;
