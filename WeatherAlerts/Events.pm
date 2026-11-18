package Plugins::WeatherAlerts::Events;

use strict;

use constant LEVELS => qw(interrupt announce display off);

# Default handling per event. OTHER covers every event not listed here.
# Groups set the headings on the settings page. Non-weather alerts appear in
# the NWS feed when officials send them through the NWS.
use constant EVENTS => (
	{ code => 'TOR', group => 'weather', name => 'Tornado Warning',             level => 'interrupt' },
	{ code => 'SVR', group => 'weather', name => 'Severe Thunderstorm Warning', level => 'interrupt' },
	{ code => 'FFW', group => 'weather', name => 'Flash Flood Warning',         level => 'interrupt' },
	{ code => 'EWW', group => 'weather', name => 'Extreme Wind Warning',        level => 'interrupt' },
	{ code => 'HUW', group => 'weather', name => 'Hurricane Warning',           level => 'interrupt' },
	{ code => 'TSW', group => 'weather', name => 'Tsunami Warning',             level => 'interrupt' },
	{ code => 'TOA', group => 'weather', name => 'Tornado Watch',               level => 'announce' },
	{ code => 'SVA', group => 'weather', name => 'Severe Thunderstorm Watch',   level => 'announce' },
	{ code => 'WSW', group => 'weather', name => 'Winter Storm Warning',        level => 'announce' },

	{ code => 'EVI', group => 'emergency', name => 'Evacuation Immediate',        level => 'interrupt' },
	{ code => 'SPW', group => 'emergency', name => 'Shelter In Place Warning',    level => 'interrupt' },
	{ code => 'CDW', group => 'emergency', name => 'Civil Danger Warning',        level => 'interrupt' },
	{ code => 'CEM', group => 'emergency', name => 'Civil Emergency Message',     level => 'interrupt' },
	{ code => 'LAE', group => 'emergency', name => 'Local Area Emergency',        level => 'interrupt' },
	{ code => 'HMW', group => 'emergency', name => 'Hazardous Materials Warning', level => 'interrupt' },
	{ code => 'NUW', group => 'emergency', name => 'Nuclear Power Plant Warning', level => 'interrupt' },
	{ code => 'RHW', group => 'emergency', name => 'Radiological Hazard Warning', level => 'interrupt' },
	{ code => 'LEW', group => 'emergency', name => 'Law Enforcement Warning',     level => 'interrupt' },
	{ code => 'FRW', group => 'emergency', name => 'Fire Warning',                level => 'interrupt' },
	{ code => 'EQW', group => 'emergency', name => 'Earthquake Warning',          level => 'interrupt' },
	{ code => 'VOW', group => 'emergency', name => 'Volcano Warning',             level => 'interrupt' },
	{ code => 'CAE', group => 'emergency', name => 'Child Abduction Emergency',   level => 'announce' },
	{ code => 'BLU', group => 'emergency', name => 'Blue Alert',                  level => 'announce' },
	{ code => 'TOE', group => 'emergency', name => '911 Telephone Outage',        level => 'display' },
	{ code => 'ADR', group => 'emergency', name => 'Administrative Message',      level => 'display' },

	{ code => 'OTHER', group => 'other', name => 'All other alerts', level => 'display' },
);

use constant GROUPS => (
	weather   => 'Weather',
	emergency => 'Non-weather emergencies',
	other     => 'Everything else',
);

my %codeForName = map { lc($_->{name}) => $_->{code} } EVENTS;

# Many alerts carry the placeholder SAME code NWS, so the event name comes first.
sub codeFor {
	my ($class, $eventName) = @_;

	return $codeForName{ lc($eventName || '') } || 'OTHER';
}

1;
