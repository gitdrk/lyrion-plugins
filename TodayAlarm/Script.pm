package Plugins::TodayAlarm::Script;

# Writes the spoken briefing and the lines shown on player screens.
# Has no Lyrion dependencies.

use strict;

my @DAYS = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
my @MONTHS = qw(January February March April May June July August September October November December);
my @NUMBERS = qw(no one two three four five six seven eight nine ten eleven twelve);

sub spokenTime {
	my ($class, $epoch) = @_;

	my ($M, $H) = (localtime $epoch)[1, 2];

	return 'Noon' if $H == 12 && $M == 0;
	return 'Midnight' if $H == 0 && $M == 0;

	my $hour = $H % 12 || 12;

	return sprintf('%d%s %s', $hour, $M ? sprintf(':%02d', $M) : '', $H < 12 ? 'AM' : 'PM');
}

sub screenTime {
	my ($class, $epoch) = @_;

	my ($M, $H) = (localtime $epoch)[1, 2];

	return sprintf('%d:%02d', $H % 12 || 12, $M) . ($H < 12 ? 'a' : 'p');
}

sub _count {
	my ($n, $word) = @_;

	my $number = $n < @NUMBERS ? $NUMBERS[$n] : $n;

	return "$number $word" . ($n == 1 ? '' : 's');
}

sub _sentence {
	my ($text) = @_;

	$text =~ s/\s+$//;

	return $text =~ /[.!?]$/ ? $text : "$text.";
}

# Args: now, events, maxEvents, problems (calendar names that failed),
# stale (calendar names using an old copy), headlines, sayFeedNames, hasCalendars.
# Returns { text => spoken text, screens => [ [line1, line2], ... ],
# clips => recorded phrase names for when there's no speech server }.
sub compose {
	my ($class, %args) = @_;

	my @now = localtime($args{now} || time);
	my $hour = $now[2];
	my $greeting = $hour < 12 ? 'Good morning' : $hour < 17 ? 'Good afternoon' : 'Good evening';
	my $date = "$DAYS[$now[6]], $MONTHS[$now[4]] $now[3]";
	my $short = substr($DAYS[$now[6]], 0, 3) . ' ' . substr($MONTHS[$now[4]], 0, 3) . " $now[3]";

	my @events = @{ $args{events} || [] };
	my $max = $args{maxEvents} || 8;
	my @spoken = ("$greeting. It's $date.");
	my @screens;
	my @clips = ('greet_' . ($hour < 12 ? 'morning' : $hour < 17 ? 'afternoon' : 'evening'), "day_$now[6]");

	if ($args{hasCalendars}) {
		my $n = scalar @events;
		push @clips, $n > 10 ? 'count_many' : "count_$n";
		push @clips, 'details' if $n;
	}

	if (!$args{hasCalendars}) {
		push @screens, [ "Today's Plan  $short", 'No calendars set up' ];
	}
	elsif (!@events) {
		push @spoken, 'Nothing on your calendar today.';
		push @screens, [ "Today's Plan  $short", 'Nothing on your calendar' ];
	}
	else {
		push @spoken, 'You have ' . _count(scalar @events, 'event') . ' today.';

		for my $event (@events[0 .. ($#events < $max - 1 ? $#events : $max - 1)]) {
			if ($event->{allDay}) {
				push @spoken, _sentence("All day, $event->{title}");
				push @screens, [ "Today's Plan  $short", "All day  $event->{title}" ];
			}
			else {
				push @spoken, _sentence($class->spokenTime($event->{start}) . ", $event->{title}");
				push @screens, [ "Today's Plan  $short", $class->screenTime($event->{start}) . "  $event->{title}" ];
			}
		}

		push @spoken, 'And ' . _count(@events - $max, 'more') . '.' if @events > $max;
	}

	push @clips, 'problem' if @{ $args{problems} || [] };

	for my $name (@{ $args{problems} || [] }) {
		push @spoken, "I couldn't load your $name calendar.";
		push @screens, [ "Today's Plan", "$name calendar unavailable" ];
	}

	for my $name (@{ $args{stale} || [] }) {
		push @spoken, "Your $name calendar may be out of date.";
	}

	my @headlines = @{ $args{headlines} || [] };

	if (@headlines) {
		push @clips, 'headlines';
		push @spoken, "Here are today's headlines.";
		my $lastFeed = '';
		my $index = 0;

		for my $headline (@headlines) {
			$index++;
			if ($args{sayFeedNames} && $headline->{feed} && $headline->{feed} ne $lastFeed) {
				push @spoken, "From $headline->{feed}.";
				$lastFeed = $headline->{feed};
			}
			push @spoken, _sentence($headline->{title});
			push @screens, [ "News  $index of " . scalar(@headlines), $headline->{title} ];
		}
	}

	push @spoken, 'Have a good day.';

	push @clips, 'goodbye';

	return { text => join(' ', @spoken), screens => \@screens, clips => \@clips };
}

1;
