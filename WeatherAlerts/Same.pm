package Plugins::WeatherAlerts::Same;

# Generates SAME audio as 16-bit mono PCM at 22050 Hz. Has no Lyrion dependencies.

use strict;

use constant RATE      => 22050;
use constant BAUD      => 520 + 5/6;
use constant MARK      => 2083 + 1/3;
use constant SPACE     => 1562.5;
use constant AMPLITUDE => 14000;
use constant TWO_PI    => 8 * atan2(1, 1);
use constant CALLSIGN  => 'LYRION00';

my %bitCache;

sub header {
	my ($class, %args) = @_;

	my @fips = @{ $args{fips} || [] };
	@fips = ('000000') if !@fips;
	$#fips = 30 if @fips > 31;

	my $minutes = $args{minutes} || 60;
	$minutes = 15 * int(($minutes + 14) / 15);
	$minutes = 360 if $minutes > 360;
	my $purge = sprintf('%02d%02d', int($minutes / 60), $minutes % 60);

	my @utc = gmtime($args{time} || time);
	my $issued = sprintf('%03d%02d%02d', $utc[7] + 1, $utc[2], $utc[1]);

	return sprintf('ZCZC-%s-%s-%s+%s-%s-%-8s-',
		$args{originator} || 'WXR', $args{event}, join('-', @fips), $purge, $issued, CALLSIGN);
}

sub _bit {
	my ($bit, $samples) = @_;

	return $bitCache{"$bit$samples"} ||= do {
		my $step = TWO_PI * ($bit ? MARK : SPACE) / RATE;
		pack('s<*', map { int(AMPLITUDE * sin($step * $_)) } 0 .. $samples - 1);
	};
}

sub afsk {
	my ($class, $text) = @_;

	my $bytes = (chr(0xAB) x 16) . $text;
	my $perBit = RATE / BAUD;
	my ($pcm, $position, $written) = ('', 0, 0);

	for my $byte (unpack('C*', $bytes)) {
		for my $shift (0 .. 7) {
			$position += $perBit;
			my $samples = int($position + 0.5) - $written;
			$written += $samples;
			$pcm .= _bit(($byte >> $shift) & 1, $samples);
		}
	}

	return $pcm;
}

sub silence {
	my ($class, $seconds) = @_;

	return "\0\0" x int(RATE * $seconds);
}

# 1050 Hz fits exactly 21 samples per cycle at this rate.
sub attentionTone {
	my ($class, $seconds) = @_;

	my $cycle = pack('s<*', map { int(AMPLITUDE * sin(TWO_PI * $_ / 21)) } 0 .. 20);

	return $cycle x int($seconds * 1050);
}

sub chime {
	my ($class) = @_;

	my $pcm = '';

	for my $frequency (880, 660) {
		my $step = TWO_PI * $frequency / RATE;
		my $samples = int(RATE * 0.35);
		$pcm .= pack('s<*', map {
			int(AMPLITUDE * sin($step * $_) * (1 - $_ / $samples))
		} 0 .. $samples - 1);
	}

	return $pcm;
}

sub burst {
	my ($class, $text) = @_;

	my $gap = $class->silence(1);
	my $signal = $class->afsk($text);

	return join($gap, $signal, $signal, $signal) . $gap;
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
