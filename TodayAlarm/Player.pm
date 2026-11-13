package Plugins::TodayAlarm::Player;

# Plays a briefing on one player, steps the screen through its lines, then puts
# back the queue, volume, repeat and power the player had before.

use strict;

use Time::HiRes;

use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant TICK         => 1;
use constant START_LIMIT  => 12;
use constant OVERRUN      => 15;
use constant FINISH_MARGIN => 1.5;
use constant SCREEN_EVERY => 4;

my $log         = logger('plugin.todayalarm');
my $serverPrefs = preferences('server');

my %running;  # master player id => job

sub isPlaying { return $running{ $_[1]->master->id } ? 1 : 0 }

sub _show {
	my ($client, $lines, $seconds, $jive) = @_;

	eval {
		$client->showBriefly({
			line => $lines,
			$jive ? (jive => { type => 'popupplay', text => $jive, duration => $seconds * 1000 }) : (),
		}, { duration => $seconds, scroll => 1, block => 0 });
	};
}

# Job: url, duration, screens (list of [line1, line2]), volume.
sub play {
	my ($class, $client, %job) = @_;

	$client = $client->master;
	my $id = $client->id;

	return $log->info('A briefing is already playing on ' . $client->name) if $running{$id};

	$job{snapshot} = {
		power   => $client->power ? 1 : 0,
		volume  => $serverPrefs->client($client)->get('volume'),
		repeat  => Slim::Player::Playlist::repeat($client) || 0,
		index   => Slim::Player::Source::playingSongIndex($client) || 0,
		queue   => [ map { ref $_ ? $_->url : $_ } @{ Slim::Player::Playlist::playList($client) } ],
		shuffle => [ @{ Slim::Player::Playlist::shuffleList($client) } ],
	};
	$job{begun} = Time::HiRes::time();
	$job{screen} = 0;
	$running{$id} = \%job;

	$client->execute(['power', 1, 1]);
	$client->execute(['mixer', 'muting', 0]);
	$client->execute(['mixer', 'volume', $job{volume}]) if $job{volume};
	$client->execute(['playlist', 'repeat', 0]);
	$client->execute(['playlist', 'play', $job{url}, "Today's Plan"]);

	if (@{ $job{screens} }) {
		_show($client, $job{screens}->[0], SCREEN_EVERY + 1, [ "Today's Plan", map { $_->[1] } @{ $job{screens} } ]);
	}

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + TICK, \&_tick, $id);
}

sub _tick {
	my ($client, $id) = @_;

	my $job = $running{$id} or return;
	$client = Slim::Player::Client::getClient($id) or return delete $running{$id};

	my $elapsed = Time::HiRes::time() - $job->{begun};
	my $mode = Slim::Player::Source::playmode($client);

	$job->{seen} ||= Time::HiRes::time() if $mode eq 'play';

	# Some players, such as SqueezePlayer, keep reporting play after a short file ends.
	my $finished = $job->{seen} && Time::HiRes::time() - $job->{seen} > $job->{duration} + FINISH_MARGIN;

	if (($job->{seen} && $mode ne 'play') || $finished || (!$job->{seen} && $elapsed > START_LIMIT) || $elapsed > $job->{duration} + OVERRUN) {
		$log->warn('The briefing never started on ' . $client->name) if !$job->{seen};
		return _restore($client, $id);
	}

	my $screen = int($elapsed / SCREEN_EVERY);
	if ($screen != $job->{screen} && $job->{screens}->[$screen]) {
		$job->{screen} = $screen;
		_show($client, $job->{screens}->[$screen], SCREEN_EVERY + 1);
	}

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + TICK, \&_tick, $id);
}

sub _restore {
	my ($client, $id) = @_;

	my $job = delete $running{$id} or return;
	my $snap = $job->{snapshot};

	Slim::Player::Playlist::stopAndClear($client);

	my @tracks = @{ $snap->{queue} };
	@{ Slim::Player::Playlist::playList($client) } = @tracks;

	my @shuffle = @{ $snap->{shuffle} };
	@shuffle = (0 .. $#tracks) if @shuffle != @tracks;
	@{ Slim::Player::Playlist::shuffleList($client) } = @shuffle;

	$client->execute(['playlist', 'repeat', $snap->{repeat}]);
	$client->execute(['playlist', 'jump', $snap->{index}, undef, 1]) if @tracks;

	my $volume = $snap->{volume};
	if (defined $volume) {
		$client->execute(['mixer', 'volume', abs $volume]);
		$client->execute(['mixer', 'muting', 1]) if $volume < 0;
	}

	$client->execute(['power', 0, 1]) if !$snap->{power};
}

sub stop {
	my ($class, $client) = @_;

	return if !$running{ $client->master->id };

	$client->master->execute(['stop']);
}

1;
