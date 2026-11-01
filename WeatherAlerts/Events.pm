package Plugins::WeatherAlerts::Events;

use strict;

use constant LEVELS => qw(interrupt announce display off);

# Default handling per event. OTHER covers every event not listed here.
use constant EVENTS => (
	{ code => 'TOR',   name => 'Tornado Warning',             level => 'interrupt' },
	{ code => 'SVR',   name => 'Severe Thunderstorm Warning', level => 'interrupt' },
	{ code => 'FFW',   name => 'Flash Flood Warning',         level => 'interrupt' },
	{ code => 'EWW',   name => 'Extreme Wind Warning',        level => 'interrupt' },
	{ code => 'HUW',   name => 'Hurricane Warning',           level => 'interrupt' },
	{ code => 'TSW',   name => 'Tsunami Warning',             level => 'interrupt' },
	{ code => 'TOA',   name => 'Tornado Watch',               level => 'announce' },
	{ code => 'SVA',   name => 'Severe Thunderstorm Watch',   level => 'announce' },
	{ code => 'WSW',   name => 'Winter Storm Warning',        level => 'announce' },
	{ code => 'OTHER', name => 'All other alerts',            level => 'display' },
);

1;
