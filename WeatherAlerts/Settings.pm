package Plugins::WeatherAlerts::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Player::Client;
use Slim::Utils::Prefs;

use Plugins::WeatherAlerts::Events;
use Plugins::WeatherAlerts::Feed;
use Plugins::WeatherAlerts::Takeover;

my $prefs = preferences('plugin.weatheralerts');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_WEATHERALERTS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/WeatherAlerts/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(zones pollSeconds alertVolume testVolume piperUrl quietEnabled quietStart quietEnd),
		map { 'level_' . $_->{code} } Plugins::WeatherAlerts::Events::EVENTS);
}

sub _key {
	my ($client) = @_;

	(my $key = $client->id) =~ s/\W//g;

	return $key;
}

sub handler {
	my ($class, $client, $params) = @_;

	my $plugin = 'Plugins::WeatherAlerts::Plugin';

	if ($params->{saveSettings}) {
		$params->{pref_quietEnabled} ||= 0;

		for my $player (Slim::Player::Client::clients()) {
			my $key = _key($player);
			my $playerPrefs = $prefs->client($player);

			$playerPrefs->set('enabled', $params->{"player_enabled_$key"} ? 1 : 0);

			my $volume = $params->{"player_volume_$key"} || 0;
			$volume = 0 if $volume !~ /^\d+$/ || $volume > 100;
			$playerPrefs->set('alertVolume', $volume);
		}
	}

	$plugin->runTest if $params->{sendTest};
	Plugins::WeatherAlerts::Takeover->stopAll if $params->{stopAlert};

	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	my $plugin = 'Plugins::WeatherAlerts::Plugin';
	my $status = Plugins::WeatherAlerts::Feed->status;

	$params->{events} = [ Plugins::WeatherAlerts::Events::EVENTS ];
	$params->{levels} = [ Plugins::WeatherAlerts::Events::LEVELS ];

	$params->{players} = [ map { {
		key     => _key($_),
		name    => $_->name,
		enabled => $plugin->enabled($_),
		volume  => $prefs->client($_)->get('alertVolume') || '',
	} } sort { $a->name cmp $b->name } grep { $_->isPlayer && $_->model ne 'group' } Slim::Player::Client::clients() ];

	$params->{feedOk}      = $status->{lastSuccess} && !$status->{lastError} ? 1 : 0;
	$params->{feedError}   = $status->{lastError};
	$params->{feedChecked} = $status->{lastSuccess} ? scalar(localtime($status->{lastSuccess})) : '';
	$params->{feedActive}  = $status->{active};
}

1;
