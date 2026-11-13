package Plugins::TodayAlarm::Feeds;

# Reads RSS and Atom feeds and picks headlines for the briefing.
# Has no Lyrion dependencies.

use strict;

use Time::Local qw(timegm);

my %MONTH = (jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6, jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12);
my %ZONE = (UT => 0, GMT => 0, Z => 0, EST => -5, EDT => -4, CST => -6, CDT => -5, MST => -7, MDT => -6, PST => -8, PDT => -7);
my %ENTITY = (amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => ' ', ndash => '-', mdash => '-', rsquo => "'", lsquo => "'", rdquo => '"', ldquo => '"', hellip => '...');

sub text {
	my ($class, $raw) = @_;

	$raw = '' if !defined $raw;
	$raw =~ s/<!\[CDATA\[(.*?)\]\]>/$1/gs;
	$raw =~ s/<[^>]*>//g;

	# Feeds often escape their HTML twice, so tags can appear after one decode.
	for (1 .. 2) {
		$raw =~ s/&#x([0-9a-fA-F]+);/chr(hex $1)/ge;
		$raw =~ s/&#(\d+);/chr($1)/ge;
		$raw =~ s/&(\w+);/exists $ENTITY{$1} ? $ENTITY{$1} : "&$1;"/ge;
		$raw =~ s/<[^>]*>//g;
	}

	$raw =~ s/\s+/ /g;
	$raw =~ s/^\s+|\s+$//g;

	return $raw;
}

sub parseTime {
	my ($class, $text) = @_;

	return undef if !$text;

	if ($text =~ /(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?(?:\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?/) {
		my $epoch = timegm($6 || 0, $5, $4, $3, $2 - 1, $1);
		if ($7 && $7 =~ /^([+-])(\d\d):?(\d\d)$/) {
			my $offset = $2 * 3600 + $3 * 60;
			$epoch += $1 eq '+' ? -$offset : $offset;
		}
		return $epoch;
	}

	if ($text =~ /(\d{1,2})\s+([A-Za-z]{3})\w*\s+(\d{2,4})\s+(\d\d):(\d\d)(?::(\d\d))?\s*([+-]\d{4}|[A-Z]{1,4})?/) {
		my $month = $MONTH{ lc $2 } or return undef;
		my $year = $3 < 100 ? $3 + 2000 : $3;
		my $epoch = timegm($6 || 0, $5, $4, $1, $month - 1, $year);
		my $zone = $7 || 'GMT';
		if ($zone =~ /^([+-])(\d\d)(\d\d)$/) {
			my $offset = $2 * 3600 + $3 * 60;
			$epoch += $1 eq '+' ? -$offset : $offset;
		}
		elsif (exists $ZONE{$zone}) {
			$epoch -= $ZONE{$zone} * 3600;
		}
		return $epoch;
	}

	return undef;
}

sub _tag {
	my ($block, @names) = @_;

	for my $name (@names) {
		return $1 if $block =~ m{<\Q$name\E(?:\s[^>]*)?>(.*?)</\Q$name\E>}s;
	}

	return undef;
}

sub parse {
	my ($class, $xml) = @_;

	my $channel = $xml;
	$channel =~ s{<(item|entry)\b.*?</\1>}{}gs;

	my @items;

	while ($xml =~ m{<(item|entry)\b[^>]*>(.*?)</\1>}gs) {
		my $block = $2;
		my $link = _tag($block, 'link');
		$link = $1 if (!defined $link || $link eq '') && $block =~ m{<link\b[^>]*href="([^"]+)"};

		push @items, {
			title => $class->text(_tag($block, 'title')),
			link  => $class->text($link),
			time  => $class->parseTime(_tag($block, 'pubDate', 'published', 'updated', 'dc:date')),
		};
	}

	return { title => $class->text(_tag($channel, 'title')), items => [ grep { $_->{title} ne '' } @items ] };
}

sub _normalize {
	my ($text) = @_;

	$text = lc($text || '');
	$text =~ s/[^\w]+/ /g;
	$text =~ s/^\s+|\s+$//g;

	return $text;
}

# Removes a trailing " - Site name" when it repeats the feed's own title.
sub cleanTitle {
	my ($class, $title, $feedTitle) = @_;

	if ($feedTitle && $title =~ /^(.*\S)\s+[-|:\x{2013}\x{2014}]\s+([^-|:\x{2013}\x{2014}]+)$/ && _normalize($2) eq _normalize($feedTitle)) {
		$title = $1;
	}

	return $title;
}

# Takes feeds as [ { name, title, items } ] in priority order and returns
# headlines as [ { feed, title } ], taking turns between feeds.
sub select {
	my ($class, %args) = @_;

	my $now = $args{now} || time;
	my $fresh = $args{freshSeconds};
	my (@queues, %seen, @picked);

	for my $feed (@{ $args{feeds} }) {
		my @items = grep { !$fresh || !$_->{time} || $now - $_->{time} <= $fresh } @{ $feed->{items} || [] };
		@items = sort { ($b->{time} || 0) <=> ($a->{time} || 0) } @items if grep { $_->{time} } @items;
		push @queues, { feed => $feed, items => \@items, taken => 0 };
	}

	while (@picked < $args{total}) {
		my $progress = 0;

		for my $queue (@queues) {
			last if @picked >= $args{total};
			next if $queue->{taken} >= $args{perFeed};

			while (my $item = shift @{ $queue->{items} }) {
				my $title = $class->cleanTitle($item->{title}, $queue->{feed}->{title});
				my @keys = ('t:' . _normalize($title), $item->{link} ? 'l:' . $item->{link} : ());
				next if grep { $seen{$_} } @keys;

				$seen{$_} = 1 for @keys;
				push @picked, { feed => $queue->{feed}->{name} || $queue->{feed}->{title} || '', title => $title };
				$queue->{taken}++;
				$progress = 1;
				last;
			}
		}

		last if !$progress;
	}

	return @picked;
}

1;
