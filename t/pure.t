use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

# The plugin's modules load as Plugins::WeatherAlerts::*.
BEGIN {
	unshift @INC, sub {
		my (undef, $file) = @_;
		return if $file !~ m{^Plugins/WeatherAlerts/(.+)$};
		my $path = File::Spec->catfile($FindBin::Bin, '..', 'WeatherAlerts', $1);
		open(my $fh, '<', $path) or return;
		return $fh;
	};
}

use Plugins::WeatherAlerts::Events;
use Plugins::WeatherAlerts::Policy;
use Plugins::WeatherAlerts::Same;

my $P = 'Plugins::WeatherAlerts::Policy';
my $S = 'Plugins::WeatherAlerts::Same';
my $E = 'Plugins::WeatherAlerts::Events';

is($E->codeFor('Tornado Warning'), 'TOR', 'event name maps to code');
is($E->codeFor('winter storm warning'), 'WSW', 'matching ignores case');
is($E->codeFor('Gale Warning'), 'OTHER', 'unknown events fall to OTHER');

is($P->parseTime('2026-11-01T09:46:00-07:00'), $P->parseTime('2026-11-01T16:46:00+00:00'), 'offsets apply');
is($P->parseTime('2026-11-01T16:46:00Z'), $P->parseTime('2026-11-01T16:46:00+00:00'), 'Z is UTC');
is($P->parseTime('nonsense'), undef, 'bad time is undef');

my $feature = {
	properties => {
		id => 'a1', event => 'Tornado Warning', status => 'Actual', messageType => 'Alert',
		headline => "Tornado Warning issued\n until 7:15PM", areaDesc => 'Floyd, IN',
		instruction => "TAKE COVER NOW!\nMove to a basement.",
		sent => '2026-11-01T18:42:00-05:00', expires => '2026-11-01T19:15:00-05:00', ends => '2026-11-01T19:15:00-05:00',
		geocode => { SAME => ['018043'], UGC => ['INC043'] },
		references => [ { identifier => 'old1' } ],
	},
};
my $alert = $P->normalize($feature);
is($alert->{code}, 'TOR', 'normalize finds the code');
is_deeply($alert->{zones}, ['INC043'], 'normalize keeps zones');
is_deeply($alert->{references}, ['old1'], 'normalize keeps references');

my %levels = map { $_->{code} => $_->{level} } $E->EVENTS;
my $now = $alert->{sent} + 60;
my $decide = sub {
	my (%over) = @_;
	return $P->decide(alert => { %$alert, messageType => 'Alert', references => [], %{ $over{alert} || {} } },
		levels => $over{levels} || \%levels, seen => $over{seen} || {}, now => $over{now} || $now, quiet => $over{quiet} || 0);
};

is($decide->(), 'interrupt', 'tornado warning interrupts');
is($decide->(quiet => 1), 'interrupt', 'tornado warning ignores quiet hours');
is($decide->(alert => { status => 'Test' }), 'ignore', 'test status never plays');
is($decide->(alert => { status => 'Exercise' }), 'ignore', 'exercise status never plays');
is($decide->(alert => { messageType => 'Cancel' }), 'ignore', 'cancel is ignored');
is($decide->(seen => { a1 => {} }), 'ignore', 'the same ID never replays');
is($decide->(now => $alert->{expires} + 1), 'ignore', 'expired alert is ignored');
is($decide->(alert => { code => 'TOA' }), 'announce', 'watch announces');
is($decide->(alert => { code => 'TOA' }, quiet => 1), 'hold', 'watch waits out quiet hours');
is($decide->(alert => { code => 'OTHER' }), 'display', 'other alerts display');
is($decide->(alert => { code => 'OTHER' }, quiet => 1), 'hold', 'display also waits');
is($decide->(levels => { %levels, TOR => 'off' }), 'ignore', 'user can turn a type off');

my %seen = (old1 => { ends => $alert->{ends}, zones => ['INC043'] });
my $update = { messageType => 'Update', references => ['old1'] };
is($decide->(alert => $update, seen => \%seen), 'display', 'routine update only displays');
is($decide->(alert => { %$update, ends => $alert->{ends} + 900 }, seen => \%seen), 'interrupt', 'longer update interrupts');
is($decide->(alert => { %$update, zones => ['INC043', 'INC061'] }, seen => \%seen), 'interrupt', 'wider update interrupts');
is($decide->(alert => { %$update, references => ['unknown'] }, seen => \%seen), 'interrupt', 'update to an unseen alert counts as new');

is($P->minutesOfDay('22:30'), 1350, 'time parses');
is($P->minutesOfDay('25:00'), undef, 'bad time rejected');
ok($P->inQuietHours(1380, 1320, 420), 'late evening is inside overnight window');
ok($P->inQuietHours(60, 1320, 420), 'early morning is inside overnight window');
ok(!$P->inQuietHours(720, 1320, 420), 'noon is outside overnight window');
ok($P->inQuietHours(600, 540, 660), 'same-day window works');
ok(!$P->inQuietHours(600, 600, 600), 'empty window is never quiet');

my $text = $P->speechText($alert);
like($text, qr/^Tornado Warning issued until 7:15PM\. For Floyd, IN\. TAKE COVER NOW! Move to a basement\.$/, 'speech text is cleaned');
my $long = $P->speechText({ %$alert, instruction => 'Stay inside. ' x 200 });
ok(length($long) <= 900, 'long speech is capped');
like($long, qr/\.$/, 'long speech ends on a sentence');

my $time = 1793511720;
my @utc = gmtime($time);
my $issued = sprintf('%03d%02d%02d', $utc[7] + 1, $utc[2], $utc[1]);
is($S->header(event => 'TOR', fips => ['018043'], minutes => 40, time => $time),
	"ZCZC-WXR-TOR-018043+0045-$issued-LYRION00-", 'header format and rounded purge');
is($S->header(event => 'DMO', time => $time), "ZCZC-WXR-DMO-000000+0100-$issued-LYRION00-", 'header defaults');
my $many = $S->header(event => 'TOR', fips => [ ('018043') x 40 ], time => $time);
is(scalar(() = $many =~ /018043/g), 31, 'header caps areas at 31');

ok(abs($S->duration($S->attentionTone(8)) - 8) < 0.01, 'tone length');
my $afsk = $S->afsk('NNNN');
my $bits = 8 * 20;
ok(abs($S->duration($afsk) - $bits / $S->BAUD) < 0.001, 'AFSK length matches bit rate');

my $wav = $S->wav("\1\0\2\0");
is(length($wav), 48, 'WAV header size');
is($S->readWav($wav), "\1\0\2\0", 'WAV round trip');
is($S->readWav('junk'), undef, 'junk WAV rejected');
my $slow = pack('a4 V a4 a4 V v v V V v v a4 V', 'RIFF', 44, 'WAVE', 'fmt ', 16, 1, 1, 11025, 22050, 2, 16, 'data', 8) . pack('s<*', 1, 2, 3, 4);
is(length($S->readWav($slow)), 16, 'other rates are resampled');

done_testing();
