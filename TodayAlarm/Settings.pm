package Plugins::TodayAlarm::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Player::Client;
use Slim::Utils::Prefs;

use Plugins::TodayAlarm::Sources;

my $prefs = preferences('plugin.todayalarm');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_TODAYALARM');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/TodayAlarm/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(perFeed totalHeadlines freshHours sayFeedNames maxEvents briefingVolume briefOnPower briefOnTimeout speechServer voice));
}

# Saved calendar links are shown shortened, so the full private link isn't on the page.
sub mask {
	my ($class, $url) = @_;

	my ($start) = $url =~ m{^(\w+://[^/]+)};

	return ($start || '') . '/...' . substr($url, -6);
}

sub _key {
	(my $key = $_[0]->id) =~ s/\W//g;
	return $key;
}

sub _lines {
	my ($text) = @_;

	return grep { $_ ne '' } map { s/^\s+|\s+$//gr } split /\r?\n/, ($text || '');
}

sub handler {
	my ($class, $client, $params) = @_;

	my $plugin = 'Plugins::TodayAlarm::Plugin';

	if ($params->{saveSettings}) {
		$params->{"pref_$_"} ||= 0 for qw(sayFeedNames briefOnPower briefOnTimeout);

		for my $service (qw(google outlook icloud)) {
			my %masked = map { $class->mask($_) => $_ } @{ $prefs->get($service) || [] };
			my @urls = map { $masked{$_} || $_ } grep { m{^(?:https?|webcal)://}i } _lines($params->{"cal_$service"});
			$prefs->set($service, \@urls);
		}

		my @feeds = map {
			my ($url, $name) = split /\s*\|\s*/, $_, 2;
			$url =~ m{^https?://}i ? { url => $url, name => $name || '' } : ();
		} _lines($params->{feedList});
		$prefs->set('feeds', \@feeds);

		for my $player (Slim::Player::Client::clients()) {
			$prefs->client($player)->set('enabled', $params->{ 'player_enabled_' . _key($player) } ? 1 : 0);
		}
	}

	if ($params->{checkNow}) {
		Plugins::TodayAlarm::Sources->refresh;
		$params->{checking} = 1;
	}

	if ($params->{playNow}) {
		my $target = Slim::Player::Client::getClient($params->{playNowPlayer} || '');
		$plugin->brief($target) if $target;
	}

	return $class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params) = @_;

	my $plugin = 'Plugins::TodayAlarm::Plugin';
	my @players = sort { $a->name cmp $b->name } grep { $_->isPlayer && $_->model ne 'group' } Slim::Player::Client::clients();

	$params->{calendars} = { map {
		my $service = $_;
		($service => join("\n", map { $class->mask($_) } @{ $prefs->get($service) || [] }));
	} qw(google outlook icloud) };

	$params->{feedList} = join("\n", map { $_->{name} ? "$_->{url} | $_->{name}" : $_->{url} } @{ $prefs->get('feeds') || [] });
	$params->{status}   = [ Plugins::TodayAlarm::Sources->status ];
	$params->{voices}   = [ $plugin->voices ];
	$params->{preview}  = $plugin->script->{text};
	$params->{players}  = [ map { { key => _key($_), id => $_->id, name => $_->name, enabled => $plugin->enabled($_) } } @players ];
}

1;
