package Plugins::WeatherAlerts::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::WeatherAlerts::Events;

my $prefs = preferences('plugin.weatheralerts');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_WEATHERALERTS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/WeatherAlerts/settings/basic.html');
}

sub prefs {
	return ($prefs, 'zones', map { 'level_' . $_->{code} } Plugins::WeatherAlerts::Events::EVENTS);
}

sub beforeRender {
	my ($class, $params) = @_;

	$params->{events} = [ Plugins::WeatherAlerts::Events::EVENTS ];
	$params->{levels} = [ Plugins::WeatherAlerts::Events::LEVELS ];
}

1;
