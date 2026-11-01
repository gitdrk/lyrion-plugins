package Plugins::WeatherAlerts::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.weatheralerts');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_WEATHERALERTS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/WeatherAlerts/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(zone));
}

1;
