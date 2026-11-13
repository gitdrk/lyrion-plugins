package Plugins::WeatherAlerts::Audio;

# Assembles the WAV file for one alert, using a Piper server for speech when
# one is configured and a pre-recorded clip otherwise.

use strict;

use File::Basename qw(dirname);
use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::WeatherAlerts::Policy;
use Plugins::WeatherAlerts::Tones;
use Plugins::WeatherAlerts::Wyoming;

use constant REPEAT_LIMIT  => 45;
use constant MAX_FILE_AGE  => 86400;
use constant PIPER_TIMEOUT => 20;

my $S     = 'Plugins::WeatherAlerts::Tones';
my $log   = logger('plugin.weatheralerts');
my $prefs = preferences('plugin.weatheralerts');

my $serial = 0;

sub cacheDir {
	my $dir = catdir(preferences('server')->get('cachedir'), 'WeatherAlerts');
	mkpath($dir) if !-d $dir;
	return $dir;
}

sub _clip {
	my ($code) = @_;

	for my $name ($code, 'OTHER') {
		my $path = catfile(dirname(__FILE__), 'Clips', "$name.wav");
		next if !-r $path;

		open(my $fh, '<:raw', $path) or next;
		local $/;
		my $bytes = <$fh>;
		close($fh);

		my $pcm = $S->readWav($bytes);
		return $pcm if defined $pcm;
	}

	$log->error('No fallback speech clip could be read');
	return $S->silence(1);
}

sub _speech {
	my ($alert, $done) = @_;

	my $server = $prefs->get('speechServer') || '';
	my $text = Plugins::WeatherAlerts::Policy->speechText($alert);

	if (my ($host, $port) = Plugins::WeatherAlerts::Wyoming->parseServer($server)) {
		return Plugins::WeatherAlerts::Wyoming->synthesize(
			host  => $host,
			port  => $port,
			voice => $prefs->get('voice'),
			text  => $text,
			done  => sub {
				my ($wav, $error) = @_;
				my $pcm = $S->readWav($wav);

				if (!defined $pcm) {
					$log->warn('Speech server failed: ' . ($error || 'unreadable audio') . '. Using the fallback clip.');
					$pcm = _clip($alert->{code});
				}

				$done->($pcm);
			},
		);
	}

	my $url = $server =~ m{^https?://}i ? $server : '';

	return $done->(_clip($alert->{code})) if !$url;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $pcm = $S->readWav(shift->content);

			if (!defined $pcm) {
				$log->warn('Piper returned audio that could not be read. Using the fallback clip.');
				$pcm = _clip($alert->{code});
			}

			$done->($pcm);
		},
		sub {
			$log->warn('Piper request failed: ' . ($_[1] || 'unknown error') . '. Using the fallback clip.');
			$done->(_clip($alert->{code}));
		},
		{ timeout => PIPER_TIMEOUT },
	)->post($url, 'Content-Type' => 'application/json', to_json({ text => $text }));
}

sub _compose {
	my ($alert, $level, $speech) = @_;

	my $voice = $speech;
	$voice .= $S->silence(1.5) . $speech if $S->duration($speech) <= REPEAT_LIMIT;

	return $S->chime . $S->silence(0.5) . $voice . $S->silence(0.5) if $level ne 'interrupt';

	return $S->alertTone . $S->silence(0.8) . $voice . $S->silence(0.8) . $S->endTone;
}

sub _prune {
	my ($dir) = @_;

	for my $file (glob(catfile($dir, 'alert-*.wav'))) {
		unlink($file) if time - (stat($file))[9] > MAX_FILE_AGE;
	}
}

# Calls $done->({ url => ..., duration => ... }), or $done->() if the file can't be written.
sub build {
	my ($class, %args) = @_;

	my ($alert, $level, $done) = @args{qw(alert level done)};

	_speech($alert, sub {
		my $pcm = _compose($alert, $level, shift);
		my $dir = cacheDir();

		_prune($dir);

		# Lyrion skips reloading when the same single item is already playing,
		# so every alert needs its own filename.
		my $file = catfile($dir, sprintf('alert-%d-%d.wav', time, ++$serial));

		if (!open(my $fh, '>:raw', $file)) {
			$log->error("Could not write $file: $!");
			return $done->();
		}
		else {
			print $fh $S->wav($pcm);
			close($fh);
		}

		$done->({
			url      => Slim::Utils::Misc::fileURLFromPath($file),
			duration => $S->duration($pcm),
		});
	});
}

1;
