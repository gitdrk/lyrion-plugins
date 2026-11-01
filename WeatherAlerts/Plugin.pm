package Plugins::WeatherAlerts::Plugin;

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::WeatherAlerts::Events;

if ( main::WEBUI ) {
	require Plugins::WeatherAlerts::Settings;
}

my $prefs = preferences('plugin.weatheralerts');

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.weatheralerts',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_WEATHERALERTS',
});

$prefs->init({
	zones => '',
	map { ('level_' . $_->{code} => $_->{level}) } Plugins::WeatherAlerts::Events::EVENTS,
});

sub getDisplayName {
	return 'PLUGIN_WEATHERALERTS';
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin();

	if ( main::WEBUI ) {
		Plugins::WeatherAlerts::Settings->new;
	}

	$log->info('Weather Alerts started, zones: ' . ($prefs->get('zones') || 'not set'));
}

1;
