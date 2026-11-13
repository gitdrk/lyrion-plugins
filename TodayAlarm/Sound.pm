package Plugins::TodayAlarm::Sound;

# Builds 16-bit mono PCM audio at 22050 Hz. Has no Lyrion dependencies.

use strict;

use constant RATE   => 22050;
use constant TWO_PI => 8 * atan2(1, 1);

sub silence {
	my ($class, $seconds) = @_;

	return "\0\0" x int(RATE * $seconds);
}

# A soft bell: a few harmonics with an exponential fade.
sub bell {
	my ($class, $frequency, $seconds, $level) = @_;

	my $samples = int(RATE * $seconds);
	my @partials = ([1, 1], [2.76, 0.35], [5.4, 0.12]);
	my $decay = 4 / $samples;

	return pack('s<*', map {
		my $t = $_;
		my $value = 0;
		$value += $_->[1] * sin(TWO_PI * $frequency * $_->[0] * $t / RATE) for @partials;
		int($level * 9000 * $value * exp(-$decay * $t) * ($t < 220 ? $t / 220 : 1));
	} 0 .. $samples - 1);
}

sub mix {
	my ($class, @tracks) = @_;

	my $length = 0;
	$length = length($_->[1]) + 2 * int(RATE * $_->[0]) > $length ? length($_->[1]) + 2 * int(RATE * $_->[0]) : $length for @tracks;

	my @sum = (0) x ($length / 2);

	for my $track (@tracks) {
		my $offset = int(RATE * $track->[0]);
		my @samples = unpack('s<*', $track->[1]);
		$sum[ $offset + $_ ] += $samples[$_] for 0 .. $#samples;
	}

	return pack('s<*', map { $_ > 32767 ? 32767 : $_ < -32768 ? -32768 : $_ } @sum);
}

# Two notes that start the briefing.
sub chime {
	my ($class) = @_;

	return $class->mix([0, $class->bell(659.25, 1.2, 0.8)], [0.35, $class->bell(987.77, 1.4, 0.7)]);
}

# The alarm sound: rising bell phrases with pauses, about 17 seconds, played on repeat.
sub morningChime {
	my ($class) = @_;

	my @notes = (523.25, 659.25, 783.99, 1046.5);
	my @tracks;
	my $time = 0.3;

	for my $phrase (0 .. 3) {
		my $level = 0.45 + 0.15 * $phrase;
		push @tracks, [ $time + 0.42 * $_, $class->bell($notes[$_], 1.6, $level) ] for 0 .. $#notes;
		$time += 4.5;
	}

	return $class->mix(@tracks);
}

sub duration {
	my ($class, $pcm) = @_;

	return length($pcm) / (2 * RATE);
}

sub wav {
	my ($class, $pcm) = @_;

	return pack('a4 V a4 a4 V v v V V v v a4 V',
		'RIFF', 36 + length($pcm), 'WAVE', 'fmt ', 16, 1, 1, RATE, RATE * 2, 2, 16, 'data', length($pcm)) . $pcm;
}

# Returns PCM in our format from a mono 16-bit WAV at any rate, or undef.
sub readWav {
	my ($class, $bytes) = @_;

	return undef if !defined $bytes || length($bytes) < 44 || substr($bytes, 0, 4) ne 'RIFF' || substr($bytes, 8, 4) ne 'WAVE';

	my ($offset, $format, $pcm) = (12);

	while ($offset + 8 <= length($bytes)) {
		my ($id, $size) = unpack('a4 V', substr($bytes, $offset, 8));
		$format = [ unpack('v v V V v v', substr($bytes, $offset + 8, 16)) ] if $id eq 'fmt ';
		if ($id eq 'data') { $pcm = substr($bytes, $offset + 8, $size); last }
		$offset += 8 + $size + ($size % 2);
	}

	return undef if !$format || !defined $pcm;

	my ($encoding, $channels, $rate, undef, undef, $bits) = @$format;

	return undef if $encoding != 1 || $bits != 16 || $channels != 1 || !$rate;
	return $pcm if $rate == RATE;

	my @input = unpack('s<*', $pcm);
	my $ratio = $rate / RATE;

	return pack('s<*', map { $input[ int($_ * $ratio) ] } 0 .. int(@input / $ratio) - 1);
}

1;
