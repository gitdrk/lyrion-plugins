# Runs the plugin's Wyoming parser against a real server with a plain socket.
#   perl t/wyoming_live.pl host:port [voice]
use strict;
use warnings;
use FindBin;
use File::Spec;
use IO::Socket::INET;

BEGIN {
	unshift @INC, sub {
		my (undef, $file) = @_;
		return if $file !~ m{^Plugins/WeatherAlerts/(.+)$};
		open(my $fh, '<', File::Spec->catfile($FindBin::Bin, '..', 'WeatherAlerts', $1)) or return;
		return $fh;
	};
}

use Plugins::WeatherAlerts::Wyoming;
my $W = 'Plugins::WeatherAlerts::Wyoming';

my ($host, $port) = $W->parseServer($ARGV[0]) or die "Use host:port\n";
my $voice = $ARGV[1] || 'en_US-lessac-medium';

sub exchange {
	my ($content, $handle) = @_;
	my $socket = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Timeout => 10) or die "connect: $!";
	print $socket $content;
	my $state = $W->newParser;
	while (sysread($socket, my $bytes, 65536)) {
		my $result = $handle->($state, $W->feed($state, $bytes));
		return @$result if $result;
	}
	die "closed early";
}

my ($info) = exchange($W->event('describe'), sub { my ($s, @e) = @_; my ($i) = grep { $_->{type} eq 'info' } @e; $i ? [ $i->{data} ] : undef });
my @voices = $W->voiceNames($info, 'en_US');
print scalar(@voices), " en_US voices\n";

my ($wav) = exchange($W->synthesizeEvent("Tornado Warning for Floyd County, Indiana. Take cover now.", $voice), sub {
	my ($s, @e) = @_;
	my $status = $W->collect($s, @e) or return;
	return [ $status eq 'done' ? $W->wav($s) : undef, $s->{error} ];
});

die "no audio" if !$wav;

printf "WAV %d bytes, %d Hz, %.1f seconds\n", length($wav), unpack('V', substr($wav, 24, 4)), (length($wav) - 44) / (2 * unpack('V', substr($wav, 24, 4)));
