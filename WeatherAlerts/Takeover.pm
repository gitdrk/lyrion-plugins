package Plugins::WeatherAlerts::Takeover;

# Takes over players for an alert, then puts each back as it was. Snapshots go
# to disk before anything changes, so a server restart can finish the restore.

use strict;

use File::Spec::Functions qw(catfile);
use JSON::XS::VersionOneAndTwo;
use Time::HiRes;

use Slim::Control::Request;
use Slim::Music::Info;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::WeatherAlerts::Audio;

use constant TICK         => 1;
use constant START_LIMIT  => 12;
use constant OVERRUN      => 20;
use constant END_MARGIN   => 3;
use constant SEEK_DELAY   => 1;
use constant PAUSE_DELAY  => 1.5;
use constant VOLUME_DELAY => 0.5;

my $log         = logger('plugin.weatheralerts');
my $serverPrefs = preferences('server');

my %snapshots;  # master player id => saved state
my %playing;    # master player id => { seen => bool } for the current job
my @queue;
my $current;

sub isActive { return $current ? 1 : 0 }

sub _file { return catfile(Plugins::WeatherAlerts::Audio->cacheDir, 'snapshots.json') }

sub _persist {
	if (!%snapshots) {
		unlink(_file());
		return;
	}

	if (open(my $fh, '>', _file())) {
		print $fh to_json(\%snapshots);
		close($fh);
	}
	else {
		$log->error("Could not save player snapshots: $!");
	}
}

sub _snapshot {
	my ($client) = @_;

	my $mode = Slim::Player::Source::playmode($client);
	my @tracks = map { ref $_ ? $_->url : $_ } @{ Slim::Player::Playlist::playList($client) };

	my %members;
	for my $member ($client->controller->allPlayers) {
		$members{ $member->id } = {
			power  => $member->power ? 1 : 0,
			volume => $serverPrefs->client($member)->get('volume'),
		};
	}

	return {
		id      => $client->id,
		mode    => $mode,
		time    => Slim::Player::Source::songTime($client) || 0,
		index   => Slim::Player::Source::playingSongIndex($client) || 0,
		repeat  => Slim::Player::Playlist::repeat($client) || 0,
		remote  => @tracks && Slim::Music::Info::isRemoteURL(Slim::Player::Playlist::url($client)) ? 1 : 0,
		queue   => \@tracks,
		shuffle => [ @{ Slim::Player::Playlist::shuffleList($client) } ],
		members => \%members,
	};
}

sub _setVolume {
	my ($client, $volume) = @_;

	return if !defined $volume;

	# Lyrion stores a muted player's volume as a negative number.
	if ($volume < 0) {
		$client->execute(['mixer', 'volume', -$volume]);
		$client->execute(['mixer', 'muting', 1]);
	}
	else {
		$client->execute(['mixer', 'muting', 0]);
		$client->execute(['mixer', 'volume', $volume]);
	}
}

sub _show {
	my ($client, $lines, $seconds) = @_;

	eval {
		$client->showBriefly({
			line => $lines,
			jive => { type => 'popupplay', text => $lines, duration => $seconds * 1000 },
		}, { duration => $seconds, scroll => 1 });
	};
}

sub show {
	my ($class, $clients, $lines, $seconds) = @_;

	_show($_, $lines, $seconds) for @$clients;
}

sub _seize {
	my ($client, $job) = @_;

	for my $member ($client->controller->allPlayers) {
		$member->execute(['power', 1, 1]);
		_setVolume($member, $job->{volume}->($member));
		_show($member, $job->{lines}, $job->{duration});
	}

	$client->execute(['playlist', 'repeat', 0]);
	$client->execute(['playlist', 'play', $job->{url}, $job->{title}]);
}

# Job: clients, url, title, lines, duration, volume (a sub taking a client).
sub start {
	my ($class, %job) = @_;

	if ($current) {
		$log->info("Queueing alert: $job{title}");
		push @queue, \%job;
		return;
	}

	_run(\%job);
}

sub _run {
	my ($job) = @_;

	my %masters;
	$masters{ $_->master->id } = $_->master for @{ $job->{clients} };

	if (!%masters) {
		$log->warn("No players are available for alert: $job->{title}");
		return _next();
	}

	$snapshots{$_} ||= _snapshot($masters{$_}) for keys %masters;
	_persist();

	$current = $job;
	$job->{begun} = Time::HiRes::time();
	%playing = map { $_ => { seen => 0 } } keys %masters;

	_seize($_, $job) for values %masters;

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + TICK, \&_tick);
}

sub _tick {
	my $job = $current or return;
	my $elapsed = Time::HiRes::time() - $job->{begun};

	for my $id (keys %playing) {
		my $client = Slim::Player::Client::getClient($id);
		my $state = $playing{$id};
		my $mode = $client ? Slim::Player::Source::playmode($client) : 'stop';

		$state->{seen} = 1 if $mode eq 'play';

		my $ended = !$client
			|| ($state->{seen} && $mode ne 'play')
			|| (!$state->{seen} && $elapsed > START_LIMIT)
			|| $elapsed > $job->{duration} + OVERRUN;

		next if !$ended;

		$log->warn("Alert never started on player $id") if !$state->{seen};
		delete $playing{$id};

		# Someone who stops the alert gets their player back right away. When
		# another alert is waiting, a player that finished naturally stays held.
		my $finished = $elapsed >= $job->{duration} - END_MARGIN;
		_restore($snapshots{$id}) if $client && !($finished && @queue);
	}

	return _next() if !%playing;

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + TICK, \&_tick);
}

sub _next {
	$current = undef;

	if (my $job = shift @queue) {
		return _run($job);
	}

	_restore($_) for grep { !$_->{restoring} } values %snapshots;
}

sub stopAll {
	my ($class) = @_;

	@queue = ();

	for my $id (keys %playing) {
		my $client = Slim::Player::Client::getClient($id) or next;
		$playing{$id}->{seen} = 1;
		$client->execute(['stop']);
	}
}

sub _restore {
	my ($snap) = @_;

	return if !$snap || $snap->{restoring};

	my $client = Slim::Player::Client::getClient($snap->{id});

	# The player is offline. The snapshot stays until it reconnects.
	return if !$client;

	$snap->{restoring} = 1;

	Slim::Player::Playlist::stopAndClear($client);

	my @tracks = @{ $snap->{queue} };
	@{ Slim::Player::Playlist::playList($client) } = @tracks;

	my @shuffle = @{ $snap->{shuffle} };
	@shuffle = (0 .. $#tracks) if @shuffle != @tracks;
	@{ Slim::Player::Playlist::shuffleList($client) } = @shuffle;

	$client->execute(['playlist', 'repeat', $snap->{repeat}]);
	Slim::Control::Request::notifyFromArray($client, ['playlist', 'load_done']);

	$client->execute(['playlist', 'jump', $snap->{index}, undef, 1]) if @tracks;

	my $resume = @tracks && $snap->{mode} =~ /^(?:play|pause)$/;

	return _finish($client, $snap) if !$resume;

	if ($snap->{mode} eq 'pause') {
		# Stay silent while the track loads and seeks.
		_setVolume($_, 0) for $client->controller->allPlayers;
	}
	else {
		_setMemberVolumes($snap);
	}

	$client->execute(['play']);

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + SEEK_DELAY, \&_seek, $snap);
}

sub _seek {
	my ($client, $snap) = @_;

	$client->execute(['time', $snap->{time}]) if !$snap->{remote} && $snap->{time} > 0.5;

	if ($snap->{mode} eq 'pause') {
		return Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + PAUSE_DELAY, \&_hold, $snap);
	}

	_finish($client, $snap);
}

sub _hold {
	my ($client, $snap) = @_;

	$client->execute(['pause', 1]);

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + VOLUME_DELAY, \&_finish, $snap);
}

sub _setMemberVolumes {
	my ($snap) = @_;

	for my $id (keys %{ $snap->{members} }) {
		my $member = Slim::Player::Client::getClient($id) or next;
		_setVolume($member, $snap->{members}->{$id}->{volume});
	}
}

sub _finish {
	my ($client, $snap) = @_;

	_setMemberVolumes($snap);

	for my $id (keys %{ $snap->{members} }) {
		next if $snap->{members}->{$id}->{power};
		my $member = Slim::Player::Client::getClient($id) or next;
		$member->execute(['power', 0, 1]);
	}

	delete $snapshots{ $snap->{id} };
	_persist();
}

sub _reconnected {
	my ($request) = @_;

	my $client = $request->client or return;
	my $snap = $snapshots{ $client->master->id } or return;

	_restore($snap) if !$current;
}

# Restores anything a server restart interrupted, now or when the player returns.
sub recover {
	my ($class) = @_;

	Slim::Control::Request::subscribe(\&_reconnected, [['client'], ['new', 'reconnect']]);

	return if !-r _file();

	if (open(my $fh, '<', _file())) {
		local $/;
		my $saved = eval { from_json(scalar <$fh>) };
		close($fh);

		%snapshots = %$saved if ref $saved eq 'HASH';
		delete $_->{restoring} for values %snapshots;
	}

	$log->info('Restoring ' . scalar(keys %snapshots) . ' player(s) after a restart') if %snapshots;

	_restore($_) for values %snapshots;
}

sub shutdown {
	Slim::Control::Request::unsubscribe(\&_reconnected);
}

1;
