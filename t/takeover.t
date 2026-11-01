use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

# A small simulation of the Lyrion modules Takeover uses, so its logic can run
# without a server. Timers fire when the test advances the clock.
my ($clock, @timers, %clients, @commands);
my $cache = tempdir(CLEANUP => 1);

BEGIN {
	unshift @INC, sub {
		my (undef, $file) = @_;
		return if $file !~ m{^Plugins/WeatherAlerts/(.+)$};
		open(my $fh, '<', File::Spec->catfile($FindBin::Bin, '..', 'WeatherAlerts', $1)) or return;
		return $fh;
	};
	$INC{$_} = 1 for qw(Slim/Control/Request.pm Slim/Music/Info.pm Slim/Player/Client.pm Slim/Player/Playlist.pm
		Slim/Player/Source.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm Slim/Utils/Timers.pm
		Slim/Networking/SimpleAsyncHTTP.pm Slim/Utils/Misc.pm JSON/XS/VersionOneAndTwo.pm);
}

{
	package FakeClient;
	sub new { my ($c, %a) = @_; return bless { power => 1, volume => 50, mode => 'stop', time => 0, index => 0, repeat => 0, queue => [], shuffle => [], members => [], %a }, $c }
	sub id { $_[0]{id} }
	sub master { $_[0]{master} || $_[0] }
	sub controller { $_[0]->master }
	sub allPlayers { my $m = shift; return ($m, @{ $m->{members} }) }
	sub power { $_[0]{power} }
	sub showBriefly { push @{ $_[0]{shown} }, $_[1]{line} }
	sub execute {
		my ($self, $cmd) = @_;
		my $m = $self->master;
		push @commands, join(' ', $self->id, map { defined $_ ? $_ : '-' } @$cmd);
		my $what = join(' ', map { defined $_ ? $_ : '' } @$cmd[0,1]);
		if ($cmd->[0] eq 'power') { $self->{power} = $cmd->[1]; $m->{mode} = 'stop' if !$cmd->[1] && !$cmd->[2] }
		elsif ($what eq 'mixer volume') { $self->{volume} = $cmd->[2] }
		elsif ($what eq 'mixer muting') { $self->{volume} = -abs($self->{volume}) if $cmd->[2] }
		elsif ($what eq 'playlist repeat') { $m->{repeat} = $cmd->[2] }
		elsif ($what eq 'playlist play') { $m->{queue} = [ $cmd->[2] ]; $m->{shuffle} = [0]; $m->{index} = 0; $m->{mode} = 'play'; $m->{time} = 0 }
		elsif ($what eq 'playlist jump') { $m->{index} = $cmd->[2] }
		elsif ($cmd->[0] eq 'play') { $m->{mode} = 'play'; $m->{time} = 0 }
		elsif ($cmd->[0] eq 'pause') { $m->{mode} = 'pause' }
		elsif ($cmd->[0] eq 'stop') { $m->{mode} = 'stop' }
		elsif ($cmd->[0] eq 'time') { $m->{time} = $cmd->[1] }
	}

	package Slim::Utils::Log;
	sub info {} sub warn {} sub error {}
	package main;
	sub logger { bless {}, 'Slim::Utils::Log' }

	package FakePrefs;
	sub get { my ($s, $k) = @_; return $s->{client} ? $s->{client}{volume} : $cache }
	sub client { bless { client => $_[1] }, 'FakePrefs' }

	package Slim::Player::Playlist;
	sub playList { $_[0]->master->{queue} }
	sub shuffleList { $_[0]->master->{shuffle} }
	sub repeat { $_[0]->master->{repeat} }
	sub url { my $m = $_[0]->master; $m->{queue}[ $m->{shuffle}[ $m->{index} ] ] }
	sub stopAndClear { my $m = $_[0]->master; $m->{mode} = 'stop'; @{ $m->{queue} } = (); @{ $m->{shuffle} } = () }

	package Slim::Player::Source;
	sub playmode { my $m = $_[0]->master; $m->{power} ? $m->{mode} : 'stop' }
	sub songTime { $_[0]->master->{time} }
	sub playingSongIndex { $_[0]->master->{index} }

	package Slim::Player::Client;
	sub getClient { $clients{ $_[0] } }

	package Slim::Music::Info;
	sub isRemoteURL { ($_[0] || '') =~ m{^http} ? 1 : 0 }

	package Slim::Control::Request;
	sub notifyFromArray {} sub subscribe {} sub unsubscribe {}

	package Slim::Utils::Timers;
	sub setTimer { my ($obj, $when, $code, @args) = @_; push @timers, [ $when, $code, $obj, @args ] }

	package Slim::Utils::Misc;
	sub fileURLFromPath { "file://$_[0]" }
}

package Plugins::WeatherAlerts::Takeover::Test;

# These must be in place before Takeover's import lines run.
BEGIN {
	no strict 'refs';
	*{'JSON::XS::VersionOneAndTwo::import'} = sub {
		my $to = caller;
		require JSON::PP;
		*{"${to}::to_json"} = sub { JSON::PP->new->canonical->encode($_[0]) };
		*{"${to}::from_json"} = sub { JSON::PP->new->decode($_[0]) };
	};
	*{'Slim::Utils::Log::import'} = sub { my $to = caller; *{"${to}::logger"} = \&main::logger };
	*{'Slim::Utils::Prefs::import'} = sub { my $to = caller; *{"${to}::preferences"} = sub { bless {}, 'FakePrefs' } };
}

package main;

use Time::HiRes;
BEGIN { no warnings; *Time::HiRes::time = sub () { $clock }; *CORE::GLOBAL::time = sub () { int($clock) } }

$clock = 1000;

require Plugins::WeatherAlerts::Takeover;
my $T = 'Plugins::WeatherAlerts::Takeover';

sub advance {
	my ($seconds, $during) = @_;
	my $end = $clock + $seconds;
	while (1) {
		@timers = sort { $a->[0] <=> $b->[0] } @timers;
		last if !@timers || $timers[0][0] > $end;
		my $t = shift @timers;
		$clock = $t->[0];
		$t->[1]->(@$t[2 .. $#$t]);
	}
	$clock = $end;
}

sub job { my (@c) = @_; return (clients => \@c, url => 'file:///alert.wav', title => 'Tornado Warning', lines => [ 'A', 'B' ], duration => 10, volume => sub { 70 }) }
sub reset_players { %clients = (); @timers = (); @commands = (); }
sub add { my %a = @_; $clients{ $a{id} } = FakeClient->new(%a) }

sub is_state {
	my ($c, $want, $name) = @_;
	is_deeply({ map { $_ => $c->{$_} } keys %$want }, $want, $name);
}

# Local track playing
reset_players();
my $k = add(id => 'kitchen', mode => 'play', time => 31, index => 1, queue => [qw(file:///a file:///b file:///c)], shuffle => [2, 0, 1], repeat => 2, volume => 35);
$T->start(job($k));
is($k->{volume}, 70, 'alert volume is set');
is($k->{repeat}, 0, 'repeat is off so the alert cannot loop');
is_deeply($k->{queue}, ['file:///alert.wav'], 'alert is playing');
ok($T->isActive, 'takeover is active');
ok(-r File::Spec->catfile($cache, 'WeatherAlerts', 'snapshots.json'), 'snapshot reaches disk before the alert ends');
advance(5);
is($k->{mode}, 'play', 'alert keeps playing');
$k->{mode} = 'stop';    # the file ended
advance(5);
is_state($k, { mode => 'play', time => 31, index => 1, repeat => 2, volume => 35 }, 'playing track returns to its position');
is_deeply($k->{queue}, [qw(file:///a file:///b file:///c)], 'queue returns');
is_deeply($k->{shuffle}, [2, 0, 1], 'shuffle order returns');
ok(!$T->isActive, 'takeover is finished');
ok(!-e File::Spec->catfile($cache, 'WeatherAlerts', 'snapshots.json'), 'snapshot is removed after restore');

# Paused track stays paused and silent while seeking
reset_players();
my $p = add(id => 'office', mode => 'pause', time => 63, queue => ['file:///a'], shuffle => [0], volume => 25);
$T->start(job($p));
advance(2);
$p->{mode} = 'stop';
advance(1.2);
is($p->{volume}, 0, 'paused player stays silent during restore');
advance(5);
is_state($p, { mode => 'pause', time => 63, volume => 25 }, 'paused track stays paused');

# Powered-off player
reset_players();
my $b = add(id => 'bedroom', power => 0, volume => 12);
$T->start(job($b));
is($b->{power}, 1, 'off player powers on');
advance(2);
$b->{mode} = 'stop';
advance(3);
is_state($b, { power => 0, volume => 12, mode => 'stop' }, 'off player returns to off');
is_deeply($b->{queue}, [], 'empty queue stays empty');

# Radio is not seeked
reset_players();
my $r = add(id => 'den', mode => 'play', time => 500, queue => ['http://radio/stream'], shuffle => [0]);
$T->start(job($r));
advance(2);
$r->{mode} = 'stop';
advance(4);
is($r->{mode}, 'play', 'radio resumes');
ok(!grep({ /^den time/ } @commands), 'radio is not seeked');

# Muted player
reset_players();
my $m = add(id => 'muted', volume => -40);
$T->start(job($m));
is($m->{volume}, 70, 'muted player is unmuted for the alert');
advance(2);
$m->{mode} = 'stop';
advance(3);
is($m->{volume}, -40, 'muted player returns muted');

# Sync group plays once and keeps each member's volume
reset_players();
my $l = add(id => 'living', mode => 'play', time => 10, queue => ['file:///a'], shuffle => [0], volume => 30);
my $d = add(id => 'dining', master => $l, volume => 60);
push @{ $l->{members} }, $d;
$T->start(job($l, $d));
is(scalar(grep { /playlist play/ } @commands), 1, 'sync group plays the alert once');
is($d->{volume}, 70, 'group member gets alert volume');
advance(2);
$l->{mode} = 'stop';
advance(4);
is($l->{volume}, 30, 'group leader volume returns');
is($d->{volume}, 60, 'group member volume returns');
is($l->{mode}, 'play', 'group resumes');

# Stopping one room restores it while the other keeps playing
reset_players();
my $one = add(id => 'one', mode => 'play', time => 5, queue => ['file:///a'], shuffle => [0]);
my $two = add(id => 'two', mode => 'play', time => 9, queue => ['file:///b'], shuffle => [0]);
$T->start(job($one, $two));
advance(2);
$one->{mode} = 'stop';
advance(3);
is($one->{queue}[0], 'file:///a', 'stopped room is restored');
is($two->{queue}[0], 'file:///alert.wav', 'other room keeps the alert');
$two->{mode} = 'stop';
advance(4);
is($two->{queue}[0], 'file:///b', 'other room restores later');

# A second alert plays next and the snapshot survives
reset_players();
my $q = add(id => 'queue', mode => 'play', time => 40, queue => ['file:///a'], shuffle => [0], volume => 22);
$T->start(job($q));
$T->start(job($q), url => 'file:///second.wav', title => 'Second');
advance(9);
$q->{mode} = 'stop';
advance(2);
is($q->{queue}[0], 'file:///second.wav', 'queued alert plays next');
advance(3);
$q->{mode} = 'stop';
advance(1);
advance(4);
is_state($q, { mode => 'play', time => 40, volume => 22 }, 'music returns after both alerts');
is_deeply($q->{queue}, ['file:///a'], 'original snapshot survives the second alert');

# A stuck player is released by the watchdog
reset_players();
my $s = add(id => 'stuck', mode => 'play', time => 7, queue => ['file:///a'], shuffle => [0]);
$T->start(job($s));
advance(35);
is($s->{queue}[0], 'file:///a', 'watchdog forces a restore');

# A player that never starts is released
reset_players();
my $n = add(id => 'never', mode => 'play', time => 3, queue => ['file:///a'], shuffle => [0]);
{
	no warnings 'redefine';
	my $real = \&FakeClient::execute;
	local *FakeClient::execute = sub { my ($self, $cmd) = @_; return if ($cmd->[1] || '') eq 'play'; $real->(@_) };
	$T->start(job($n));
	$n->{mode} = 'stop';
	advance(20);
}
ok(!$T->isActive, 'a player that never starts is released');

# Restart recovery
reset_players();
my $w = add(id => 'restart', mode => 'play', time => 88, queue => ['file:///a'], shuffle => [0], volume => 33);
my $file = File::Spec->catfile($cache, 'WeatherAlerts', 'snapshots.json');
open(my $fh, '>', $file) or die $!;
print $fh JSON::PP->new->encode({ restart => { id => 'restart', mode => 'play', time => 88, index => 0, repeat => 1, remote => 0, queue => ['file:///a'], shuffle => [0], members => { restart => { power => 1, volume => 33 } } } });
close($fh);
$w->{queue} = ['file:///alert.wav'];
$w->{volume} = 70;
$T->recover;
advance(3);
is_state($w, { mode => 'play', time => 88, volume => 33, repeat => 1 }, 'restart finishes the restore');
ok(!-e $file, 'snapshot is removed after recovery');

done_testing();
