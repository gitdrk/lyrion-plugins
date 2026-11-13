package Plugins::TodayAlarm::Ics;

# Reads iCalendar files and finds the events on one local day, including
# repeating events, exceptions and moved occurrences. Has no Lyrion dependencies.
# Time zones come from each file's VTIMEZONE blocks, because Lyrion ships no
# time zone database. Zones a file doesn't define are treated as server time.

use strict;

use Time::Local qw(timegm timelocal);

use constant MAX_COUNT_DAYS => 4000;

my %WEEKDAY = (SU => 0, MO => 1, TU => 2, WE => 3, TH => 4, FR => 5, SA => 6);

sub _unescape {
	my ($text) = @_;

	$text =~ s/\\([nN])/\n/g;
	$text =~ s/\\([,;\\])/$1/g;

	return $text;
}

sub _property {
	my ($line) = @_;

	my ($name, $rest) = $line =~ /^([A-Za-z0-9-]+)(.*)$/s or return;
	my %params;

	while ($rest =~ s/^;([A-Za-z0-9-]+)=("[^"]*"|[^;:]*)//) {
		my ($key, $value) = (uc $1, $2);
		$value =~ s/^"|"$//g;
		$params{$key} = $value;
	}

	return if $rest !~ s/^://;

	return (uc $name, { params => \%params, value => $rest });
}

sub parse {
	my ($class, $text) = @_;

	$text =~ s/\r?\n[ \t]//g;

	my (@stack, @events, %zones);

	for my $line (split /\r?\n/, $text) {
		next if $line eq '';

		if ($line =~ /^BEGIN:(\S+)/i) {
			push @stack, { type => uc $1, props => {}, children => [] };
			next;
		}

		if ($line =~ /^END:(\S+)/i) {
			my $done = pop @stack or next;
			my $parent = $stack[-1];

			if ($done->{type} eq 'VEVENT') {
				push @events, $done->{props};
			}
			elsif ($done->{type} eq 'VTIMEZONE') {
				my $tzid = _first($done->{props}, 'TZID');
				$zones{$tzid} = [ map { _observance($_) } @{ $done->{children} } ] if defined $tzid;
			}
			elsif ($parent) {
				push @{ $parent->{children} }, $done;
			}
			next;
		}

		my ($name, $prop) = _property($line) or next;
		push @{ $stack[-1]->{props}->{$name} }, $prop if @stack;
	}

	return { events => \@events, zones => \%zones };
}

sub _first {
	my ($props, $name) = @_;

	my $prop = ($props->{$name} || [])->[0];

	return $prop ? $prop->{value} : undef;
}

sub _offset {
	my ($text) = @_;

	my ($sign, $h, $m, $s) = ($text || '') =~ /^([+-])(\d\d)(\d\d)(\d\d)?$/ or return 0;
	my $seconds = $h * 3600 + $m * 60 + ($s || 0);

	return $sign eq '-' ? -$seconds : $seconds;
}

sub _observance {
	my ($component) = @_;

	my $props = $component->{props};
	my ($y, $m, $d, $H, $M, $S) = (_first($props, 'DTSTART') || '') =~ /^(\d{4})(\d\d)(\d\d)(?:T(\d\d)(\d\d)(\d\d))?/;

	return {
		start  => [ $y || 1970, $m || 1, $d || 1, $H || 0, $M || 0, $S || 0 ],
		to     => _offset(_first($props, 'TZOFFSETTO')),
		from   => _offset(_first($props, 'TZOFFSETFROM')),
		rule   => _rule(_first($props, 'RRULE')),
	};
}

sub _rule {
	my ($text) = @_;

	return if !$text;

	my %rule = map { my ($k, $v) = split /=/, $_, 2; (uc $k => $v) } split /;/, $text;

	$rule{INTERVAL} ||= 1;
	$rule{BYDAY} = [ map { /^([+-]?\d*)([A-Z]{2})$/ ? { n => $1 eq '' ? 0 : $1 + 0, day => $WEEKDAY{$2} } : () } split /,/, uc($rule{BYDAY} || '') ];
	$_ = [ split /,/, $_ ] for grep { defined } @rule{qw(BYMONTH BYMONTHDAY BYSETPOS)};
	$rule{WKST} = $WEEKDAY{ uc($rule{WKST} || 'MO') } // 1;

	return \%rule;
}

# Day numbers count days since 1970 and make date arithmetic simple.
sub dayNumber {
	my ($y, $m, $d) = @_;

	return int(timegm(0, 0, 12, $d, $m - 1, $y) / 86400);
}

sub fromDayNumber {
	my ($n) = @_;

	my @t = gmtime($n * 86400 + 43200);

	return ($t[5] + 1900, $t[4] + 1, $t[3], $t[6]);
}

sub _daysInMonth {
	my ($y, $m) = @_;

	my ($ny, $nm) = $m == 12 ? ($y + 1, 1) : ($y, $m + 1);

	return dayNumber($ny, $nm, 1) - dayNumber($y, $m, 1);
}

# All day numbers in a month that are the given weekday.
sub _weekdaysInMonth {
	my ($y, $m, $weekday) = @_;

	my $first = dayNumber($y, $m, 1);
	my $firstWeekday = (fromDayNumber($first))[3];
	my $day = $first + (($weekday - $firstWeekday) % 7);
	my $last = $first + _daysInMonth($y, $m);
	my @days;

	for (; $day < $last; $day += 7) { push @days, $day }

	return @days;
}

# The days a BYDAY or BYMONTHDAY rule picks in one month.
sub _monthDays {
	my ($rule, $y, $m, $defaultDay) = @_;

	my $first = dayNumber($y, $m, 1);
	my $length = _daysInMonth($y, $m);
	my @days;

	if ($rule->{BYMONTHDAY}) {
		for my $md (@{ $rule->{BYMONTHDAY} }) {
			my $day = $md > 0 ? $md : $length + $md + 1;
			push @days, $first + $day - 1 if $day >= 1 && $day <= $length;
		}
	}
	elsif (@{ $rule->{BYDAY} }) {
		for my $by (@{ $rule->{BYDAY} }) {
			my @all = _weekdaysInMonth($y, $m, $by->{day});
			if (!$by->{n}) { push @days, @all }
			elsif ($by->{n} > 0) { push @days, $all[ $by->{n} - 1 ] if $by->{n} <= @all }
			else { push @days, $all[ $by->{n} ] if -$by->{n} <= @all }
		}
	}
	else {
		push @days, $first + $defaultDay - 1 if $defaultDay <= $length;
	}

	@days = sort { $a <=> $b } @days;

	if ($rule->{BYSETPOS} && @days) {
		@days = map { $_ > 0 ? $days[ $_ - 1 ] : $days[$_] } grep { abs($_) <= @days } @{ $rule->{BYSETPOS} };
	}

	return grep { defined } @days;
}

# Whether the rule produces an occurrence on day $day, ignoring COUNT and UNTIL.
sub _onDay {
	my ($rule, $start, $day) = @_;

	return 0 if $day < $start;

	my ($sy, $sm, $sd, $sw) = fromDayNumber($start);
	my ($y, $m, $d, $w) = fromDayNumber($day);
	my $interval = $rule->{INTERVAL};
	my $freq = $rule->{FREQ} || '';
	my %months = map { $_ => 1 } @{ $rule->{BYMONTH} || [] };

	return 0 if %months && !$months{$m};

	if ($freq eq 'DAILY') {
		return 0 if ($day - $start) % $interval;
		return 1 if !@{ $rule->{BYDAY} };
		return scalar grep { $_->{day} == $w } @{ $rule->{BYDAY} };
	}

	if ($freq eq 'WEEKLY') {
		my $weekStart = sub { $_[0] - ((((fromDayNumber($_[0]))[3]) - $rule->{WKST}) % 7) };
		return 0 if (($weekStart->($day) - $weekStart->($start)) / 7) % $interval;
		my @days = @{ $rule->{BYDAY} } ? map { $_->{day} } @{ $rule->{BYDAY} } : ($sw);
		return scalar grep { $_ == $w } @days;
	}

	if ($freq eq 'MONTHLY') {
		return 0 if (($y * 12 + $m) - ($sy * 12 + $sm)) % $interval;
		return scalar grep { $_ == $day } _monthDays($rule, $y, $m, $sd);
	}

	if ($freq eq 'YEARLY') {
		return 0 if ($y - $sy) % $interval;
		return 0 if !%months && $m != $sm;
		return scalar grep { $_ == $day } _monthDays($rule, $y, $m, $sd);
	}

	return 0;
}

sub _countReached {
	my ($rule, $start, $day) = @_;

	return 0 if !$rule->{COUNT};
	return 1 if $day - $start > MAX_COUNT_DAYS;

	my $seen = 0;

	for my $candidate ($start .. $day) {
		$seen++ if _onDay($rule, $start, $candidate);
		return 1 if $seen > $rule->{COUNT};
	}

	return 0;
}

sub _wall {
	my ($value) = @_;

	my ($y, $m, $d, $H, $M, $S, $z) = ($value || '') =~ /^(\d{4})(\d\d)(\d\d)(?:T(\d\d)(\d\d)(\d\d)(Z)?)?/ or return;

	return { date => [ $y, $m, $d ], time => defined $H ? [ $H, $M, $S ] : undef, utc => $z ? 1 : 0 };
}

# The UTC offset of a zone at a wall-clock moment, from its observances.
sub _zoneOffset {
	my ($observances, $y, $m, $d, $H, $M, $S) = @_;

	my $moment = timegm($S, $M, $H, $d, $m - 1, $y);
	my ($best, $bestOnset);

	for my $o (@$observances) {
		my @onsets;
		my ($oy, $om, $od, $oH, $oM, $oS) = @{ $o->{start} };

		if ($o->{rule} && ($o->{rule}->{FREQ} || '') eq 'YEARLY') {
			for my $year ($y - 1, $y) {
				next if $year < $oy;
				my @months = @{ $o->{rule}->{BYMONTH} || [$om] };
				for my $month (@months) {
					push @onsets, map { my ($a, $b, $c) = fromDayNumber($_); timegm($oS, $oM, $oH, $c, $b - 1, $a) }
						_monthDays($o->{rule}, $year, $month, $od);
				}
			}
		}
		else {
			push @onsets, timegm($oS, $oM, $oH, $od, $om - 1, $oy);
		}

		for my $onset (@onsets) {
			next if $onset > $moment;
			($best, $bestOnset) = ($o, $onset) if !defined $bestOnset || $onset > $bestOnset;
		}
	}

	return $best ? $best->{to} : (@$observances ? $observances->[0]->{from} : undef);
}

sub _epoch {
	my ($wall, $date, $tzid, $zones) = @_;

	my ($y, $m, $d) = @$date;
	my ($H, $M, $S) = @{ $wall->{time} };

	return timegm($S, $M, $H, $d, $m - 1, $y) if $wall->{utc};

	if ($tzid && $zones->{$tzid}) {
		my $offset = _zoneOffset($zones->{$tzid}, $y, $m, $d, $H, $M, $S);
		return timegm($S, $M, $H, $d, $m - 1, $y) - $offset if defined $offset;
	}

	return timelocal($S, $M, $H, $d, $m - 1, $y);
}

sub _duration {
	my ($text) = @_;

	my ($sign, $w, $d, $h, $m, $s) = ($text || '') =~ /^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/ or return;
	my $seconds = (($w || 0) * 7 + ($d || 0)) * 86400 + ($h || 0) * 3600 + ($m || 0) * 60 + ($s || 0);

	return ($sign || '') eq '-' ? -$seconds : $seconds;
}

# Events overlapping local day $y-$m-$d, as hashes with title, location, uid,
# allDay and start (an epoch, undef for all-day events).
sub eventsOn {
	my ($class, $calendar, $y, $m, $d) = @_;

	my $today = dayNumber($y, $m, $d);
	my $dayStart = timelocal(0, 0, 0, $d, $m - 1, $y);
	my ($ny, $nm, $nd) = fromDayNumber($today + 1);
	my $dayEnd = timelocal(0, 0, 0, $nd, $nm - 1, $ny);
	my $zones = $calendar->{zones};

	my (%moved, @found);

	# Moved or cancelled single occurrences replace the matching repeat.
	for my $props (@{ $calendar->{events} }) {
		my $rid = ($props->{'RECURRENCE-ID'} || [])->[0] or next;
		my $wall = _wall($rid->{value}) or next;
		my $key = $wall->{time} ? _epoch($wall, $wall->{date}, $rid->{params}->{TZID}, $zones) : dayNumber(@{ $wall->{date} });
		$moved{ (_first($props, 'UID') || '') . "|$key" } = 1;
	}

	for my $props (@{ $calendar->{events} }) {
		next if uc(_first($props, 'STATUS') || '') eq 'CANCELLED';

		my $startProp = ($props->{DTSTART} || [])->[0] or next;
		my $wall = _wall($startProp->{value}) or next;
		my $tzid = $startProp->{params}->{TZID};
		my $allDay = !$wall->{time};
		my $uid = _first($props, 'UID') || '';
		my $rule = $props->{'RECURRENCE-ID'} ? undef : _rule(_first($props, 'RRULE'));

		my $startDay = dayNumber(@{ $wall->{date} });
		my $endProp = ($props->{DTEND} || [])->[0];
		my $endWall = $endProp ? _wall($endProp->{value}) : undef;

		my ($spanDays, $length);
		if ($allDay) {
			$spanDays = $endWall ? dayNumber(@{ $endWall->{date} }) - $startDay : 1;
			if (my $duration = _duration(_first($props, 'DURATION'))) { $spanDays = int($duration / 86400) }
			$spanDays = 1 if $spanDays < 1;
		}
		else {
			my $start = _epoch($wall, $wall->{date}, $tzid, $zones);
			$length = $endWall && $endWall->{time}
				? _epoch($endWall, $endWall->{date}, $endProp->{params}->{TZID} || $tzid, $zones) - $start
				: (_duration(_first($props, 'DURATION')) || 0);
			$length = 0 if $length < 0;
			$spanDays = int($length / 86400) + 1;
		}

		my %excluded;
		for my $ex (@{ $props->{EXDATE} || [] }) {
			for my $value (split /,/, $ex->{value}) {
				my $exWall = _wall($value) or next;
				my $key = $exWall->{time} ? _epoch($exWall, $exWall->{date}, $ex->{params}->{TZID} || $tzid, $zones) : dayNumber(@{ $exWall->{date} });
				$excluded{$key} = 1;
			}
		}

		my $until;
		if ($rule && $rule->{UNTIL}) {
			my $untilWall = _wall($rule->{UNTIL});
			$until = !$untilWall ? undef
				: $untilWall->{time} ? _epoch($untilWall, $untilWall->{date}, $tzid, $zones)
				: dayNumber(@{ $untilWall->{date} });
		}

		my @candidates = $rule ? (grep { _onDay($rule, $startDay, $_) } ($today - $spanDays - 1) .. ($today + 1)) : ($startDay);

		for my $day (@candidates) {
			my $date = [ (fromDayNumber($day))[0 .. 2] ];

			if ($allDay) {
				next if $today < $day || $today >= $day + $spanDays;
				next if $rule && defined $until && $day > $until;
				next if $excluded{$day} || ($rule && $moved{"$uid|$day"});
				next if $rule && _countReached($rule, $startDay, $day);
				push @found, { title => _unescape(_first($props, 'SUMMARY') || 'Untitled event'), location => _unescape(_first($props, 'LOCATION') || ''), uid => $uid, allDay => 1, start => undef, day => $day };
				next;
			}

			my $start = _epoch($wall, $date, $tzid, $zones);
			my $end = $start + $length;
			my $overlaps = $length ? ($start < $dayEnd && $end > $dayStart) : ($start >= $dayStart && $start < $dayEnd);
			next if !$overlaps;
			next if $rule && defined $until && $start > $until;
			next if $excluded{$start} || ($rule && $moved{"$uid|$start"});
			next if $rule && _countReached($rule, $startDay, $day);

			push @found, { title => _unescape(_first($props, 'SUMMARY') || 'Untitled event'), location => _unescape(_first($props, 'LOCATION') || ''), uid => $uid, allDay => 0, start => $start };
		}
	}

	return @found;
}

sub _normalize {
	my ($text) = @_;

	$text = lc($text || '');
	$text =~ s/[^\w]+/ /g;
	$text =~ s/^\s+|\s+$//g;

	return $text;
}

# Merges events from several calendars, given in priority order as [ [events], ... ].
# The same event appearing twice is kept once.
sub merge {
	my ($class, @lists) = @_;

	my (@kept, %byKey);

	for my $priority (0 .. $#lists) {
		for my $event (@{ $lists[$priority] }) {
			my $when = $event->{allDay} ? 'day' . $event->{day} : $event->{start};
			my @keys = ('title|' . _normalize($event->{title}) . "|$when");
			unshift @keys, "uid|$event->{uid}|$when" if $event->{uid};

			my ($existing) = grep { defined } map { $byKey{$_} } @keys;

			if ($existing) {
				my $better = (!$existing->{location} && $event->{location})
					|| (!!$existing->{location} == !!$event->{location} && length($event->{title}) > length($existing->{title}));
				%$existing = %$event if $better;
			}
			else {
				$existing = { %$event };
				push @kept, $existing;
			}

			$byKey{$_} = $existing for @keys;
		}
	}

	return sort {
		($b->{allDay} <=> $a->{allDay}) || (($a->{start} || 0) <=> ($b->{start} || 0)) || ($a->{title} cmp $b->{title})
	} @kept;
}

1;
