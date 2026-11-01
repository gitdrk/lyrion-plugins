use strict;
use warnings;
use FindBin;
use File::Spec;

# Writes an alert in the same order Audio.pm assembles one, for tools/decode_same.py.
BEGIN {
	unshift @INC, sub {
		my (undef, $file) = @_;
		return if $file !~ m{^Plugins/WeatherAlerts/(.+)$};
		open(my $fh, '<', File::Spec->catfile($FindBin::Bin, '..', 'WeatherAlerts', $1)) or return;
		return $fh;
	};
}

use Plugins::WeatherAlerts::Same;

my $S = 'Plugins::WeatherAlerts::Same';
my $header = $S->header(event => 'TOR', fips => ['018043'], minutes => 45, time => 1793511720);
my $pcm = $S->burst($header) . $S->attentionTone(8) . $S->silence(2) . $S->burst('NNNN');

open(my $fh, '>:raw', $ARGV[0]) or die $!;
print $fh $S->wav($pcm);
close($fh);
print "$header\n";
