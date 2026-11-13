package Plugins::TodayAlarm::Sources;

# Downloads calendars and feeds on a schedule and keeps the last good copy on
# disk, so a briefing never waits on the network. Calendar links are private,
# so they never reach the log; calendars are named by service instead.

use strict;

use Digest::MD5 qw(md5_hex);
use Encode;
use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::TodayAlarm::Feeds;
use Plugins::TodayAlarm::Ics;

use constant SERVICES => ([ google => 'Google' ], [ outlook => 'Outlook' ], [ icloud => 'iCloud' ]);
use constant STALE    => 6 * 3600;
use constant TIMEOUT  => 30;

my $log   = logger('plugin.todayalarm');
my $prefs = preferences('plugin.todayalarm');

my %copies;   # url => { body, fetched, error, tried }
my $lastRefresh = 0;

sub cacheDir {
	my $dir = catdir(preferences('server')->get('cachedir'), 'TodayAlarm');
	mkpath($dir) if !-d $dir;
	return $dir;
}

sub _file { return catfile(cacheDir(), md5_hex($_[0]) . '.txt') }

sub fetchUrl {
	my ($class, $url) = @_;

	(my $fixed = $url) =~ s{^webcal://}{https://}i;

	return $fixed;
}

sub calendars {
	my @list;

	for my $service (SERVICES) {
		my ($key, $label) = @$service;
		my @urls = grep { $_ } @{ $prefs->get($key) || [] };
		my $n = 0;
		push @list, map { { service => $key, label => @urls > 1 ? "$label " . ++$n : $label, url => $_ } } @urls;
	}

	return @list;
}

sub feeds {
	return grep { $_->{url} } @{ $prefs->get('feeds') || [] };
}

sub _load {
	my ($url) = @_;

	return $copies{$url} if $copies{$url};

	my $copy = $copies{$url} = {};

	if (open(my $fh, '<:encoding(UTF-8)', _file($url))) {
		my $first = <$fh>;
		local $/;
		$copy->{body} = <$fh>;
		$copy->{fetched} = $first + 0;
		close($fh);
	}

	return $copy;
}

sub _store {
	my ($url, $body) = @_;

	if (open(my $fh, '>:encoding(UTF-8)', _file($url))) {
		print $fh time, "\n", $body;
		close($fh);
	}
}

sub refresh {
	my ($class, $done) = @_;

	my @urls = ((map { $_->{url} } calendars()), (map { $_->{url} } feeds()));
	my $pending = scalar @urls;

	$lastRefresh = time;

	return $done && $done->() if !$pending;

	my $finish = sub { $done->() if --$pending == 0 && $done };

	for my $url (@urls) {
		my $copy = _load($url);
		$copy->{tried} = time;

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $body = Encode::decode('UTF-8', shift->content, Encode::FB_DEFAULT);
				$copy->{body} = $body;
				$copy->{fetched} = time;
				$copy->{error} = '';
				_store($url, $body);
				$finish->();
			},
			sub {
				$copy->{error} = $_[1] || 'Unknown error';
				$finish->();
			},
			{ timeout => TIMEOUT, cache => 0 },
		)->get($class->fetchUrl($url));
	}
}

sub lastRefresh { return $lastRefresh }

# Returns (\@events, \@problemNames, \@staleNames) for the local day containing $now.
sub today {
	my ($class, $now) = @_;

	my ($d, $m, $y) = (localtime($now || time))[3, 4, 5];
	my (%byService, @problems, @stale);

	for my $calendar (calendars()) {
		my $copy = _load($calendar->{url});

		if (!$copy->{body}) {
			push @problems, $calendar->{label};
			next;
		}

		push @stale, $calendar->{label} if time - ($copy->{fetched} || 0) > STALE;

		my @events = eval {
			Plugins::TodayAlarm::Ics->eventsOn(Plugins::TodayAlarm::Ics->parse($copy->{body}), $y + 1900, $m + 1, $d);
		};

		if ($@) {
			$log->warn("Could not read the $calendar->{label} calendar: $@");
			push @problems, $calendar->{label};
			next;
		}

		push @{ $byService{ $calendar->{service} } }, @events;
	}

	my @events = Plugins::TodayAlarm::Ics->merge(map { $byService{ $_->[0] } || [] } SERVICES);

	return (\@events, \@problems, \@stale);
}

sub headlines {
	my ($class, $now) = @_;

	my @parsed = map {
		my $copy = _load($_->{url});
		$copy->{body} ? { name => $_->{name}, %{ Plugins::TodayAlarm::Feeds->parse($copy->{body}) } } : ();
	} feeds();

	return Plugins::TodayAlarm::Feeds->select(
		feeds        => \@parsed,
		perFeed      => $prefs->get('perFeed') || 2,
		total        => $prefs->get('totalHeadlines') || 5,
		freshSeconds => ($prefs->get('freshHours') || 24) * 3600,
		now          => $now || time,
	);
}

# For the settings page: one row per calendar and feed, without the private links.
sub status {
	my ($class) = @_;

	my @rows;

	for my $item ((map { { %$_, kind => 'Calendar' } } calendars()), (map { { %$_, kind => 'Feed', label => $_->{name} || $_->{url} } } feeds())) {
		my $copy = _load($item->{url});
		my $headline;

		if ($item->{kind} eq 'Feed' && $copy->{body}) {
			my $feed = Plugins::TodayAlarm::Feeds->parse($copy->{body});
			$headline = $feed->{items}->[0] ? $feed->{items}->[0]->{title} : 'No headlines found';
		}

		push @rows, {
			kind     => $item->{kind},
			label    => $item->{label},
			ok       => $copy->{body} && !$copy->{error} ? 1 : 0,
			fetched  => $copy->{fetched} ? scalar localtime($copy->{fetched}) : 'Never',
			error    => $copy->{error} || '',
			headline => $headline || '',
		};
	}

	return @rows;
}

1;
