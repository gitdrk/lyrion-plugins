package Plugins::WeatherAlerts::Tones;

# The plugin's own alert sounds, as 16-bit mono PCM at 22050 Hz. Has no Lyrion
# dependencies.
#
# These deliberately aren't Emergency Alert System or Wireless Emergency Alert
# sounds. There are no SAME data bursts, and no steady tone near 853, 960 or
# 1050 Hz or the SAME data frequencies of 1562.5 and 2083.3 Hz. t/pure.t
# measures this.

use strict;

use constant RATE      => 22050;
use constant AMPLITUDE => 13000;
use constant TWO_PI    => 8 * atan2(1, 1);
use constant FADE      => 0.012;

sub silence {
	my ($class, $seconds) = @_;

	return "\0\0" x int(RATE * $seconds);
}

# A tone whose pitch glides from $from to $to Hz, with short fades so it never clicks.
sub glide {
	my ($class, $from, $to, $seconds, $level) = @_;

	my $samples = int(RATE * $seconds);
	my $fade = int(RATE * FADE);
	my $phase = 0;
	my @out;

	for my $i (0 .. $samples - 1) {
		my $frequency = $from + ($to - $from) * $i / $samples;
		$phase += TWO_PI * $frequency / RATE;
		my $envelope = $i < $fade ? $i / $fade : $i > $samples - $fade ? ($samples - $i) / $fade : 1;
		push @out, int(($level || 1) * AMPLITUDE * $envelope * sin($phase));
	}

	return pack('s<*', @out);
}

sub beep {
	my ($class, $frequency, $seconds, $level) = @_;

	return $class->glide($frequency, $frequency, $seconds, $level);
}

# The opening alert: three rising sweeps, then quick alternating beeps, twice. About 7 seconds.
sub alertTone {
	my ($class) = @_;

	my $sweeps = join('', map { $class->glide(1150, 1500, 0.55) . $class->silence(0.15) } 1 .. 3);
	my $beeps = join('', map { $class->beep($_ % 2 ? 1250 : 1700, 0.12) . $class->silence(0.07) } 1 .. 6);
	my $round = $sweeps . $class->silence(0.15) . $beeps;

	return $round . $class->silence(0.45) . $round;
}

# The closing sound: two falling notes.
sub endTone {
	my ($class) = @_;

	return $class->beep(1400, 0.25, 0.8) . $class->silence(0.05) . $class->beep(1180, 0.45, 0.7);
}

# The softer opening for alerts that only interrupt players already on.
sub chime {
	my ($class) = @_;

	my $pcm = '';

	for my $frequency (1175, 784) {
		my $samples = int(RATE * 0.35);
		my $step = TWO_PI * $frequency / RATE;
		$pcm .= pack('s<*', map { int(AMPLITUDE * sin($step * $_) * (1 - $_ / $samples)) } 0 .. $samples - 1);
	}

	return $pcm;
}

sub duration {
	my ($class, $pcm) = @_;

	return length($pcm) / (2 * RATE);
}

sub wav {
	my ($class, $pcm) = @_;

	my $size = length($pcm);

	return pack('a4 V a4 a4 V v v V V v v a4 V',
		'RIFF', 36 + $size, 'WAVE', 'fmt ', 16, 1, 1, RATE, RATE * 2, 2, 16, 'data', $size) . $pcm;
}

# Returns PCM at our format, or undef if the data isn't usable.
sub readWav {
	my ($class, $bytes) = @_;

	return undef if !defined $bytes || length($bytes) < 44 || substr($bytes, 0, 4) ne 'RIFF' || substr($bytes, 8, 4) ne 'WAVE';

	my ($offset, $format, $pcm) = (12);

	while ($offset + 8 <= length($bytes)) {
		my ($id, $size) = unpack('a4 V', substr($bytes, $offset, 8));

		if ($id eq 'fmt ') {
			$format = [ unpack('v v V V v v', substr($bytes, $offset + 8, 16)) ];
		}
		elsif ($id eq 'data') {
			$pcm = substr($bytes, $offset + 8, $size);
			last;
		}

		$offset += 8 + $size + ($size % 2);
	}

	return undef if !$format || !defined $pcm;

	my ($encoding, $channels, $rate, undef, undef, $bits) = @$format;

	return undef if $encoding != 1 || $bits != 16 || $channels != 1 || !$rate;
	return $pcm if $rate == RATE;

	my @input = unpack('s<*', $pcm);
	my $ratio = $rate / RATE;
	my $count = int(@input / $ratio);

	return pack('s<*', map { $input[ int($_ * $ratio) ] } 0 .. $count - 1);
}

1;
