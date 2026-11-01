package Plugins::WeatherAlerts::Policy;

# Decides what happens with an alert. Has no Lyrion dependencies.

use strict;

use Time::Local qw(timegm);

use Plugins::WeatherAlerts::Events;

use constant MAX_SPEECH => 900;

sub parseTime {
	my ($class, $text) = @_;

	return undef if !$text;

	my ($y, $m, $d, $H, $M, $S, $zone) = $text =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:\d\d)?$/;
	return undef if !defined $y;

	my $epoch = timegm($S, $M, $H, $d, $m - 1, $y);

	if ($zone && $zone =~ /^([+-])(\d\d):(\d\d)$/) {
		my $offset = $2 * 3600 + $3 * 60;
		$epoch += $1 eq '+' ? -$offset : $offset;
	}

	return $epoch;
}

# Turns one NWS GeoJSON feature into the shape every alert source must produce.
sub normalize {
	my ($class, $feature) = @_;

	my $p = $feature->{properties} || {};
	my $geocode = $p->{geocode} || {};

	return {
		source      => 'nws',
		id          => $p->{id},
		event       => $p->{event} || 'Weather Alert',
		code        => Plugins::WeatherAlerts::Events->codeFor($p->{event}),
		headline    => $p->{headline} || '',
		instruction => $p->{instruction} || '',
		area        => $p->{areaDesc} || '',
		status      => $p->{status} || '',
		messageType => $p->{messageType} || '',
		references  => [ map { $_->{identifier} } @{ $p->{references} || [] } ],
		sent        => $class->parseTime($p->{sent}),
		ends        => $class->parseTime($p->{ends}) || $class->parseTime($p->{expires}),
		expires     => $class->parseTime($p->{expires}),
		zones       => [ sort @{ $geocode->{UGC} || [] } ],
		fips        => [ @{ $geocode->{SAME} || [] } ],
	};
}

sub zonesAdded {
	my ($class, $new, $old) = @_;

	my %known = map { $_ => 1 } @{ $old || [] };

	return scalar grep { !$known{$_} } @{ $new || [] };
}

# An update only sounds again if it reaches further or lasts longer.
sub isMaterialUpdate {
	my ($class, $alert, $seen) = @_;

	my @previous = grep { $_ } map { $seen->{$_} } @{ $alert->{references} };

	return 1 if !@previous;

	my $latestEnd = 0;
	my @zones;

	for my $old (@previous) {
		$latestEnd = $old->{ends} if ($old->{ends} || 0) > $latestEnd;
		push @zones, @{ $old->{zones} || [] };
	}

	return 1 if ($alert->{ends} || 0) > $latestEnd;
	return 1 if $class->zonesAdded($alert->{zones}, \@zones);
	return 0;
}

sub minutesOfDay {
	my ($class, $text) = @_;

	return undef if ($text || '') !~ /^(\d{1,2}):(\d\d)$/ || $1 > 23 || $2 > 59;

	return $1 * 60 + $2;
}

sub inQuietHours {
	my ($class, $minute, $start, $end) = @_;

	return 0 if !defined $start || !defined $end || $start == $end;
	return ($minute >= $start && $minute < $end) ? 1 : 0 if $start < $end;
	return ($minute >= $start || $minute < $end) ? 1 : 0;
}

# Args: alert, levels (code => level), seen (id => record), now, quiet (true or false).
# Returns: interrupt, announce, display, hold or ignore.
sub decide {
	my ($class, %args) = @_;

	my $alert = $args{alert};

	return 'ignore' if $alert->{status} ne 'Actual';
	return 'ignore' if $alert->{messageType} eq 'Cancel';
	return 'ignore' if !$alert->{id} || $args{seen}->{ $alert->{id} };
	return 'ignore' if $alert->{expires} && $alert->{expires} <= $args{now};

	my $level = $args{levels}->{ $alert->{code} } || $args{levels}->{OTHER} || 'display';

	return 'ignore' if $level eq 'off';

	if ($alert->{messageType} eq 'Update' && !$class->isMaterialUpdate($alert, $args{seen})) {
		return $args{quiet} ? 'ignore' : 'display';
	}

	return 'hold' if $args{quiet} && $level ne 'interrupt';

	return $level;
}

sub clean {
	my ($class, $text) = @_;

	$text = defined $text ? $text : '';
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;

	return $text;
}

sub speechText {
	my ($class, $alert) = @_;

	my @parts = ($class->clean($alert->{headline}) || $alert->{event});
	push @parts, 'For ' . $class->clean($alert->{area}) if $alert->{area};
	push @parts, $class->clean($alert->{instruction}) if $alert->{instruction};

	my $text = join('. ', @parts);
	$text =~ s/\.\.+/./g;

	if (length($text) > MAX_SPEECH) {
		$text = substr($text, 0, MAX_SPEECH);
		$text =~ s/[^.]*$//;
	}

	return $text;
}

1;
