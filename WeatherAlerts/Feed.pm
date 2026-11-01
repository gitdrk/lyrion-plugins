package Plugins::WeatherAlerts::Feed;

# The National Weather Service alert source. Another source only has to hand
# the plugin alerts in the shape Policy->normalize produces.

use strict;

use JSON::XS::VersionOneAndTwo;
use Time::HiRes;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::WeatherAlerts::Policy;

use constant URL        => 'https://api.weather.gov/alerts/active';
use constant USER_AGENT => '(lyrion-plugins, https://github.com/gitdrk/lyrion-plugins)';
use constant TIMEOUT    => 20;

my $log   = logger('plugin.weatheralerts');
my $prefs = preferences('plugin.weatheralerts');

my $onAlerts;
my %status = (lastSuccess => 0, lastError => '', active => 0);

sub status { return { %status } }

sub zones {
	my ($class) = @_;

	my @zones = grep { /^[A-Z]{2}[CZ]\d{3}$/ } split(/[\s,]+/, uc($prefs->get('zones') || ''));

	return @zones;
}

sub start {
	my ($class, $callback) = @_;

	$onAlerts = $callback;
	$class->poll;
}

sub stop {
	Slim::Utils::Timers::killTimers(undef, \&poll);
}

sub _schedule {
	my ($class) = @_;

	Slim::Utils::Timers::killTimers(undef, \&poll);
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($prefs->get('pollSeconds') || 60), \&poll);
}

sub poll {
	my $class = __PACKAGE__;
	my @zones = $class->zones;

	if (!@zones) {
		$status{lastError} = 'No valid alert zones are set.';
		return $class->_schedule;
	}

	Slim::Networking::SimpleAsyncHTTP->new(\&_response, \&_failure, { timeout => TIMEOUT })->get(
		URL . '?zone=' . join(',', @zones),
		'User-Agent' => USER_AGENT,
		'Accept'     => 'application/geo+json',
	);
}

sub _failure {
	my ($http, $error) = @_;

	$status{lastError} = $error || 'Unknown error';
	$log->warn("Alert feed request failed: $status{lastError}");

	__PACKAGE__->_schedule;
}

sub _response {
	my ($http) = @_;

	my $data = eval { from_json($http->content) };

	if ($@ || ref $data ne 'HASH' || ref $data->{features} ne 'ARRAY') {
		return _failure($http, 'The alert feed returned data that could not be read.');
	}

	my @alerts = map { Plugins::WeatherAlerts::Policy->normalize($_) } @{ $data->{features} };

	$status{lastSuccess} = time;
	$status{lastError}   = '';
	$status{active}      = scalar @alerts;

	$onAlerts->(\@alerts) if $onAlerts;

	__PACKAGE__->_schedule;
}

1;
