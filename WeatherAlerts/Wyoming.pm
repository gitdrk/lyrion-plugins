package Plugins::WeatherAlerts::Wyoming;

# Client for a Wyoming text-to-speech server, such as Home Assistant's Piper add-on.
# Parser is pure Perl; synthesize() and voices() use Lyrion's non-blocking sockets.
# Keep in step with TodayAlarm/Wyoming.pm: t/wyoming.t checks the copies match.

use strict;

use constant TIMEOUT => 30;

use JSON::PP;

my $JSON = JSON::PP->new->utf8->canonical;

sub _json { return $JSON }

# Accepts host:port, optionally with a tcp:// prefix.
sub parseServer {
	my ($class, $text) = @_;

	return if !defined $text;

	my ($host, $port) = $text =~ m{^\s*(?:tcp://)?([\w.\-]+):(\d+)/?\s*$}i;

	return $host ? ($host, $port) : ();
}

sub event {
	my ($class, $type, $data) = @_;

	return _json()->encode({ type => $type }) . "\n" if !$data;

	my $body = _json()->encode($data);

	return _json()->encode({ type => $type, data_length => length($body) }) . "\n" . $body;
}

sub synthesizeEvent {
	my ($class, $text, $voice) = @_;

	return $class->event('synthesize', { text => $text, $voice ? (voice => { name => $voice }) : () });
}

sub newParser { return { buffer => '', pcm => '' } }

# Takes received bytes and returns the complete events found so far.
sub feed {
	my ($class, $state, $bytes) = @_;

	$state->{buffer} .= $bytes;

	my @events;

	while (1) {
		my $newline = index($state->{buffer}, "\n");
		last if $newline < 0;

		my $header = eval { _json()->decode(substr($state->{buffer}, 0, $newline)) };
		return (@events, { type => 'error', data => { text => 'Unreadable reply from speech server' } }) if !$header;

		my $dataLength = $header->{data_length} || 0;
		my $payloadLength = $header->{payload_length} || 0;
		my $total = $newline + 1 + $dataLength + $payloadLength;
		last if length($state->{buffer}) < $total;

		my $data = $header->{data} || {};
		if ($dataLength) {
			my $extra = eval { _json()->decode(substr($state->{buffer}, $newline + 1, $dataLength)) } || {};
			$data = { %$data, %$extra };
		}

		push @events, {
			type    => $header->{type},
			data    => $data,
			payload => substr($state->{buffer}, $newline + 1 + $dataLength, $payloadLength),
		};

		substr($state->{buffer}, 0, $total) = '';
	}

	return @events;
}

# Collects audio events. Returns 'done', 'error' or nothing while still waiting.
sub collect {
	my ($class, $state, @events) = @_;

	for my $event (@events) {
		my $type = $event->{type} || '';

		if ($type eq 'audio-start' || ($type eq 'audio-chunk' && !$state->{format})) {
			$state->{format} = { map { $_ => $event->{data}->{$_} } qw(rate width channels) };
		}

		$state->{pcm} .= $event->{payload} if $type eq 'audio-chunk';

		return 'done' if $type eq 'audio-stop';

		if ($type eq 'error') {
			$state->{error} = $event->{data}->{text} || 'Speech server error';
			return 'error';
		}
	}

	return;
}

# Wraps collected audio as a WAV file.
sub wav {
	my ($class, $state) = @_;

	my $format = $state->{format} || {};
	my ($rate, $width, $channels) = ($format->{rate} || 22050, $format->{width} || 2, $format->{channels} || 1);
	my $pcm = $state->{pcm};

	return pack('a4 V a4 a4 V v v V V v v a4 V',
		'RIFF', 36 + length($pcm), 'WAVE', 'fmt ', 16, 1, $channels, $rate, $rate * $width * $channels,
		$width * $channels, $width * 8, 'data', length($pcm)) . $pcm;
}

sub voiceNames {
	my ($class, $info, $prefix) = @_;

	my @names = map { $_->{name} } map { @{ $_->{voices} || [] } } @{ $info->{tts} || [] };
	@names = grep { index($_, $prefix) == 0 } @names if $prefix;

	return sort @names;
}

# Sends one event and reads replies until $handle returns a result.
sub _exchange {
	my ($class, %args) = @_;

	require Slim::Networking::Async;
	require Slim::Utils::Timers;
	require Time::HiRes;

	my $state = $class->newParser;
	my ($finished, $onTimeout);

	my $finish = sub {
		my ($result, $error) = @_;
		return if $finished++;
		Slim::Utils::Timers::killTimers($state, $onTimeout);
		$args{done}->($result, $error);
	};

	$onTimeout = sub { $finish->(undef, 'The speech server took too long') };
	Slim::Utils::Timers::setTimer($state, Time::HiRes::time() + ($args{timeout} || TIMEOUT), $onTimeout);

	my $async = Slim::Networking::Async->new;
	my $content = $args{content};

	$async->write_async({
		host        => $args{host},
		port        => $args{port},
		skipDNS     => 1,
		Timeout     => 10,
		content_ref => \$content,
		onError     => sub {
			my ($self, $error) = @_;
			$finish->(undef, $error || 'Could not reach the speech server');
		},
		onRead      => sub {
			my ($self) = @_;

			my $bytes = '';
			my $read = $self->socket->sysread($bytes, 65536);

			if (!$read) {
				$self->disconnect;
				return $finish->(undef, 'The speech server closed the connection');
			}

			my $result = $args{handle}->($state, $class->feed($state, $bytes));

			if (defined $result) {
				$self->disconnect;
				$finish->(@$result);
			}
		},
	});
}

# Calls $done->($wavBytes) or $done->(undef, $error).
sub synthesize {
	my ($class, %args) = @_;

	$class->_exchange(
		%args,
		content => $class->synthesizeEvent($args{text}, $args{voice}),
		handle  => sub {
			my ($state, @events) = @_;
			my $status = $class->collect($state, @events) or return;
			return $status eq 'done' ? [ $class->wav($state) ] : [ undef, $state->{error} ];
		},
	);
}

# Calls $done->(\%info) or $done->(undef, $error).
sub describe {
	my ($class, %args) = @_;

	$class->_exchange(
		%args,
		timeout => 10,
		content => $class->event('describe'),
		handle  => sub {
			my ($state, @events) = @_;
			my ($info) = grep { $_->{type} eq 'info' } @events;
			return $info ? [ $info->{data} ] : undef;
		},
	);
}

1;
