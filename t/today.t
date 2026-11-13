use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use POSIX qw(tzset);
use Time::Local qw(timegm timelocal);

# Run as if the server were in U.S. Eastern time.
BEGIN { $ENV{TZ} = 'EST5EDT,M3.2.0,M11.1.0'; tzset(); }

BEGIN {
	unshift @INC, sub {
		my (undef, $file) = @_;
		my ($plugin, $rest) = $file =~ m{^Plugins/(TodayAlarm|WeatherAlerts)/(.+)$} or return;
		open(my $fh, '<', File::Spec->catfile($FindBin::Bin, '..', $plugin, $rest)) or return;
		return $fh;
	};
}

use Plugins::TodayAlarm::Ics;
use Plugins::TodayAlarm::Feeds;
use Plugins::TodayAlarm::Script;
use Plugins::TodayAlarm::Sound;
use Plugins::TodayAlarm::Wyoming;

my $I = 'Plugins::TodayAlarm::Ics';
my $F = 'Plugins::TodayAlarm::Feeds';
my $S = 'Plugins::TodayAlarm::Script';

sub cal { return "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" . join('', @_) . "END:VCALENDAR\r\n" }
sub ev { my %p = @_; return "BEGIN:VEVENT\r\n" . join('', map { "$_\r\n" } @{ $p{lines} }) . "END:VEVENT\r\n" }

my $NY = "BEGIN:VTIMEZONE\r\nTZID:America/New_York\r\n"
	. "BEGIN:DAYLIGHT\r\nTZOFFSETFROM:-0500\r\nTZOFFSETTO:-0400\r\nDTSTART:19700308T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU\r\nEND:DAYLIGHT\r\n"
	. "BEGIN:STANDARD\r\nTZOFFSETFROM:-0400\r\nTZOFFSETTO:-0500\r\nDTSTART:19701101T020000\r\nRRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n";
my $LA = "BEGIN:VTIMEZONE\r\nTZID:Pacific Standard Time\r\n"
	. "BEGIN:STANDARD\r\nDTSTART:16010101T020000\r\nTZOFFSETFROM:-0700\r\nTZOFFSETTO:-0800\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11\r\nEND:STANDARD\r\n"
	. "BEGIN:DAYLIGHT\r\nDTSTART:16010101T020000\r\nTZOFFSETFROM:-0800\r\nTZOFFSETTO:-0700\r\nRRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3\r\nEND:DAYLIGHT\r\nEND:VTIMEZONE\r\n";

sub on {
	my ($text, $y, $m, $d) = @_;
	return $I->eventsOn($I->parse($text), $y, $m, $d);
}

sub titles { return join(',', map { $_->{title} } @_) }
sub local_epoch { my ($y, $m, $d, $H, $M) = @_; return timelocal(0, $M, $H, $d, $m - 1, $y) }

# Single events, zones and daylight saving
my $basic = cal($NY, $LA,
	ev(lines => [ 'UID:a', 'SUMMARY:Standup', 'DTSTART;TZID=America/New_York:20261112T090000', 'DTEND;TZID=America/New_York:20261112T091500' ]),
	ev(lines => [ 'UID:b', 'SUMMARY:West coast call', 'DTSTART;TZID=Pacific Standard Time:20261112T100000', 'DURATION:PT1H' ]),
	ev(lines => [ 'UID:c', 'SUMMARY:UTC thing', 'DTSTART:20261112T170000Z', 'DTEND:20261112T173000Z' ]),
	ev(lines => [ 'UID:d', 'SUMMARY:Tomorrow', 'DTSTART;TZID=America/New_York:20261113T090000' ]),
	ev(lines => [ 'UID:e', 'SUMMARY:Holiday', 'DTSTART;VALUE=DATE:20261112', 'DTEND;VALUE=DATE:20261113' ]),
	ev(lines => [ 'UID:f', 'SUMMARY:Trip', 'DTSTART;VALUE=DATE:20261110', 'DTEND;VALUE=DATE:20261114' ]),
	ev(lines => [ 'UID:g', 'SUMMARY:Late show', 'DTSTART;TZID=America/New_York:20261111T230000', 'DTEND;TZID=America/New_York:20261112T010000' ]),
	ev(lines => [ 'UID:h', 'SUMMARY:Called off', 'STATUS:CANCELLED', 'DTSTART;TZID=America/New_York:20261112T150000' ]),
	ev(lines => [ 'UID:i', 'SUMMARY:Floating', 'DTSTART:20261112T200000' ]),
	ev(lines => [ 'UID:j', 'SUMMARY:Summer', 'DTSTART;TZID=America/New_York:20260715T090000' ]),
	ev(lines => [ 'UID:k', 'SUMMARY:Lunch\, with Sam', 'LOCATION:Cafe', 'DTSTART;TZID=America/New_York:20261112T123000' ]),
);
my @day = on($basic, 2026, 11, 12);
my %by = map { $_->{title} => $_ } @day;
is($by{Standup}{start}, local_epoch(2026, 11, 12, 9, 0), 'New York zone in winter');
is($by{'West coast call'}{start}, local_epoch(2026, 11, 12, 13, 0), 'Windows Pacific zone converts');
is($by{'UTC thing'}{start}, local_epoch(2026, 11, 12, 12, 0), 'UTC converts');
ok(!$by{Tomorrow}, 'tomorrow is left out');
ok($by{Holiday}{allDay}, 'all-day event today');
ok($by{Trip}{allDay}, 'multi-day event covers today');
ok($by{'Late show'}, 'event running past midnight shows the next day');
ok(!$by{'Called off'}, 'cancelled event is left out');
is($by{Floating}{start}, local_epoch(2026, 11, 12, 20, 0), 'floating time is server time');
is($by{'Lunch, with Sam'}{location}, 'Cafe', 'escaped comma and location');
my ($summer) = on($basic, 2026, 7, 15);
is($summer->{start}, local_epoch(2026, 7, 15, 9, 0), 'New York zone in summer');
ok(!grep({ $_->{title} eq 'Trip' } on($basic, 2026, 11, 14)), 'multi-day event ends on its end date');

# Repeats
my $repeats = cal($NY,
	ev(lines => [ 'UID:w', 'SUMMARY:Weekly MWF', 'DTSTART;TZID=America/New_York:20260105T080000', 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR' ]),
	ev(lines => [ 'UID:w2', 'SUMMARY:Every other Thursday', 'DTSTART;TZID=America/New_York:20261029T100000', 'RRULE:FREQ=WEEKLY;INTERVAL=2' ]),
	ev(lines => [ 'UID:m', 'SUMMARY:Second Thursday', 'DTSTART;TZID=America/New_York:20260108T190000', 'RRULE:FREQ=MONTHLY;BYDAY=2TH' ]),
	ev(lines => [ 'UID:m2', 'SUMMARY:Last Friday', 'DTSTART;TZID=America/New_York:20260130T170000', 'RRULE:FREQ=MONTHLY;BYDAY=-1FR' ]),
	ev(lines => [ 'UID:m3', 'SUMMARY:Rent', 'DTSTART;VALUE=DATE:20260112', 'RRULE:FREQ=MONTHLY' ]),
	ev(lines => [ 'UID:y', 'SUMMARY:Birthday', 'DTSTART;VALUE=DATE:19901112', 'RRULE:FREQ=YEARLY' ]),
	ev(lines => [ 'UID:d', 'SUMMARY:Pills', 'DTSTART;TZID=America/New_York:20261101T070000', 'RRULE:FREQ=DAILY;COUNT=5' ]),
	ev(lines => [ 'UID:d2', 'SUMMARY:Short course', 'DTSTART;TZID=America/New_York:20261101T070000', 'RRULE:FREQ=DAILY;COUNT=20' ]),
	ev(lines => [ 'UID:u', 'SUMMARY:Ended', 'DTSTART;TZID=America/New_York:20260101T090000', 'RRULE:FREQ=DAILY;UNTIL=20261110T235959Z' ]),
	ev(lines => [ 'UID:x', 'SUMMARY:Skipped today', 'DTSTART;TZID=America/New_York:20260101T110000', 'RRULE:FREQ=DAILY', 'EXDATE;TZID=America/New_York:20261112T110000' ]),
	ev(lines => [ 'UID:r', 'SUMMARY:Team sync', 'DTSTART;TZID=America/New_York:20260101T140000', 'RRULE:FREQ=DAILY' ]),
	ev(lines => [ 'UID:r', 'SUMMARY:Team sync (moved)', 'RECURRENCE-ID;TZID=America/New_York:20261112T140000', 'DTSTART;TZID=America/New_York:20261112T160000' ]),
	ev(lines => [ 'UID:c', 'SUMMARY:Gym', 'DTSTART;TZID=America/New_York:20260101T060000', 'RRULE:FREQ=DAILY' ]),
	ev(lines => [ 'UID:c', 'SUMMARY:Gym', 'STATUS:CANCELLED', 'RECURRENCE-ID;TZID=America/New_York:20261112T060000', 'DTSTART;TZID=America/New_York:20261112T060000' ]),
	ev(lines => [ 'UID:wd', 'SUMMARY:Last weekday', 'DTSTART;TZID=America/New_York:20260130T080000', 'RRULE:FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1' ]),
);
my %r = map { $_->{title} => $_ } on($repeats, 2026, 11, 12);
ok(!$r{'Weekly MWF'}, 'weekly rule skips Thursday');
ok(scalar(grep { $_->{title} eq 'Weekly MWF' } on($repeats, 2026, 11, 13)), 'weekly rule hits Friday');
ok($r{'Every other Thursday'}, 'every other week, on week');
ok(!grep({ $_->{title} eq 'Every other Thursday' } on($repeats, 2026, 11, 19)), 'every other week, off week');
ok($r{'Second Thursday'}, 'second Thursday of the month');
ok(!grep({ $_->{title} eq 'Second Thursday' } on($repeats, 2026, 11, 19)), 'not the third Thursday');
ok(scalar(grep { $_->{title} eq 'Last Friday' } on($repeats, 2026, 11, 27)), 'last Friday of the month');
ok($r{Rent} && $r{Rent}{allDay}, 'monthly on the same date');
ok($r{Birthday}, 'yearly all-day event');
ok(!$r{Pills}, 'count of five ended before day twelve');
ok($r{'Short course'}, 'count of twenty still running');
ok(!$r{Ended}, 'until date has passed');
ok(!$r{'Skipped today'}, 'excluded date is skipped');
ok(scalar(grep { $_->{title} eq 'Skipped today' } on($repeats, 2026, 11, 13)), 'excluded date only skips one day');
ok(!$r{'Team sync'}, 'moved occurrence leaves its old slot');
is($r{'Team sync (moved)'}{start}, local_epoch(2026, 11, 12, 16, 0), 'moved occurrence shows at its new time');
ok(!$r{Gym}, 'cancelled occurrence is removed');
ok(scalar(grep { $_->{title} eq 'Gym' } on($repeats, 2026, 11, 13)), 'cancelling one occurrence keeps the rest');
ok(scalar(grep { $_->{title} eq 'Last weekday' } on($repeats, 2026, 11, 30)), 'last weekday of the month');
ok(!grep({ $_->{title} eq 'Last weekday' } on($repeats, 2026, 11, 27)), 'not an earlier weekday');
is((grep { $_->{title} eq 'Team sync' } on($repeats, 2026, 7, 1))[0]{start}, local_epoch(2026, 7, 1, 14, 0), 'repeat keeps wall time across daylight saving');

# Folded long lines and LF-only files
my $folded = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:z\nSUMMARY:A very long\n  title that folds\nDTSTART:20261112T150000Z\nEND:VEVENT\nEND:VCALENDAR\n";
is(titles(on($folded, 2026, 11, 12)), 'A very long title that folds', 'folded lines and LF endings');

# Merging three calendars
my $s1 = local_epoch(2026, 11, 12, 9, 0);
my @google = ({ title => 'Standup', uid => 'u1', start => $s1, allDay => 0, location => '' }, { title => 'Holiday', uid => 'h', allDay => 1, day => 1, location => '' });
my @outlook = ({ title => 'standup', uid => 'other', start => $s1, allDay => 0, location => 'Room 4' }, { title => 'Dentist', uid => 'd', start => $s1 + 3600 * 7, allDay => 0, location => '' });
my @icloud = ({ title => 'Standup', uid => 'u1', start => $s1, allDay => 0, location => '' }, { title => 'Early run', uid => 'e', start => $s1 - 7200, allDay => 0, location => '' });
my @merged = $I->merge(\@google, \@outlook, \@icloud);
is(titles(@merged), 'Holiday,Early run,standup,Dentist', 'merged, sorted, all-day first, duplicates once');
is((grep { lc $_->{title} eq 'standup' } @merged)[0]{location}, 'Room 4', 'the copy with a location wins');

# Feeds
my $rss = <<'XML';
<rss><channel><title>Local News</title>
<item><title><![CDATA[Bridge reopens &amp; traffic eases - Local News]]></title><link>https://x/1</link><pubDate>Thu, 12 Nov 2026 10:00:00 GMT</pubDate></item>
<item><title>Old story</title><link>https://x/2</link><pubDate>Mon, 09 Nov 2026 10:00:00 -0500</pubDate></item>
<item><title>School board &lt;b&gt;votes&lt;/b&gt;</title><link>https://x/3</link><pubDate>Thu, 12 Nov 2026 08:00:00 EST</pubDate></item>
<item><title>Shared story</title><link>https://shared/1</link><pubDate>Thu, 12 Nov 2026 07:00:00 GMT</pubDate></item>
</channel></rss>
XML
my $atom = <<'XML';
<feed xmlns="http://www.w3.org/2005/Atom"><title>World</title>
<entry><title type="html">Summit ends</title><link href="https://w/1"/><updated>2026-11-12T11:00:00Z</updated></entry>
<entry><title>Shared story</title><link href="https://shared/1"/><published>2026-11-12T09:30:00-05:00</published></entry>
<entry><title>Markets rise</title><link href="https://w/3"/><updated>2026-11-12T06:00:00Z</updated></entry>
</feed>
XML
my $local = $F->parse($rss);
my $world = $F->parse($atom);
is($local->{title}, 'Local News', 'RSS title');
is($world->{title}, 'World', 'Atom title');
is(scalar @{ $world->{items} }, 3, 'Atom entries');
is($world->{items}[0]{link}, 'https://w/1', 'Atom link');
is($F->parseTime('2026-11-12T09:30:00-05:00'), timegm(0, 30, 14, 12, 10, 2026), 'ISO time with offset');
is($F->parseTime('Thu, 12 Nov 2026 08:00:00 EST'), timegm(0, 0, 13, 12, 10, 2026), 'RFC time with named zone');
my $now = timegm(0, 0, 12, 12, 10, 2026);
my @picked = $F->select(feeds => [ { name => 'Local', %$local }, { name => '', %$world } ], perFeed => 2, total => 5, freshSeconds => 86400, now => $now);
is(join('|', map { "$_->{feed}:$_->{title}" } @picked), 'Local:School board votes|World:Shared story|Local:Bridge reopens & traffic eases|World:Summit ends',
	'newest first, turns between feeds, cleans titles, caps per feed, drops stale and duplicate');
is(scalar($F->select(feeds => [ { %$local }, { %$world } ], perFeed => 3, total => 2, freshSeconds => 86400, now => $now)), 2, 'total cap');
is($F->text('A&#8217;s &#x41; &nbsp;b'), "A\x{2019}s A b", 'numeric entities');

# Briefing text
my $morning = local_epoch(2026, 11, 12, 6, 41);
my $brief = $S->compose(now => $morning, hasCalendars => 1, maxEvents => 2, sayFeedNames => 1,
	events => [ { title => 'Holiday', allDay => 1 }, { title => 'Standup', start => local_epoch(2026, 11, 12, 9, 0) }, { title => 'Lunch', start => local_epoch(2026, 11, 12, 12, 0) } ],
	problems => ['Outlook'], headlines => [ { feed => 'Local', title => 'Bridge reopens' }, { feed => 'Local', title => 'Vote today!' } ]);
is($brief->{text}, "Good morning. It's Thursday, November 12. You have three events today. All day, Holiday. 9 AM, Standup. And one more. "
	. "I couldn't load your Outlook calendar. Here are today's headlines. From Local. Bridge reopens. Vote today! Have a good day.", 'spoken briefing');
is($brief->{screens}[1][1], '9:00a  Standup', 'screen line for a timed event');
is(join(',', @{ $brief->{clips} }), 'greet_morning,day_4,count_3,details,problem,headlines,goodbye', 'recorded phrases for the same briefing');
is(join(',', @{ $S->compose(now => $morning, hasCalendars => 1)->{clips} }), 'greet_morning,day_4,count_0,goodbye', 'recorded phrases for an empty day');
is(join(',', @{ $S->compose(now => $morning, hasCalendars => 1, events => [ map { { title => "E$_", start => $morning } } 1 .. 12 ])->{clips} }), 'greet_morning,day_4,count_many,details,goodbye', 'recorded phrases for a busy day');
my %clip = map { s/\.wav$//r => 1 } map { (split m{/})[-1] } glob("$FindBin::Bin/../TodayAlarm/Clips/*.wav");
ok($clip{$_}, "recorded phrase $_ exists") for qw(greet_morning greet_afternoon greet_evening count_many details headlines problem goodbye), (map { "day_$_" } 0 .. 6), (map { "count_$_" } 0 .. 10);
is($S->spokenTime(local_epoch(2026, 11, 12, 12, 0)), 'Noon', 'noon');
is($S->spokenTime(local_epoch(2026, 11, 12, 16, 30)), '4:30 PM', 'afternoon time');
like($S->compose(now => $morning, hasCalendars => 1)->{text}, qr/Nothing on your calendar today\./, 'empty day');
unlike($S->compose(now => $morning, hasCalendars => 0)->{text}, qr/calendar/, 'no calendars set says nothing about them');
like($S->compose(now => local_epoch(2026, 11, 12, 18, 0), hasCalendars => 1)->{text}, qr/^Good evening/, 'evening greeting');

# Sounds
my $snd = 'Plugins::TodayAlarm::Sound';
ok(abs($snd->duration($snd->morningChime) - 16.7) < 1, 'alarm chime is about 17 seconds');
ok($snd->duration($snd->chime) < 2.5, 'briefing chime is short');
is(length($snd->readWav($snd->wav("\1\0\2\0"))), 4, 'WAV round trip');

# Wyoming parser
my $W = 'Plugins::TodayAlarm::Wyoming';
is_deeply([ $W->parseServer('tcp://192.168.1.205:30546') ], [ '192.168.1.205', 30546 ], 'server with tcp prefix');
is_deeply([ $W->parseServer('nas.local:10200') ], [ 'nas.local', 10200 ], 'server by name');
is_deeply([ $W->parseServer('https://x:1/path') ], [], 'URL is not a Wyoming server');
my $chunkData = q({"rate": 22050, "width": 2, "channels": 1});
my $stream = qq({"type": "audio-start", "data": {"rate": 22050, "width": 2, "channels": 1}}\n)
	. qq({"type": "audio-chunk", "data_length": ) . length($chunkData) . qq(, "payload_length": 4}\n$chunkData\1\0\2\0)
	. qq({"type": "audio-stop"}\n);
my $state = $W->newParser;
my $status;
for my $i (0 .. length($stream) - 1) {
	$status ||= $W->collect($state, $W->feed($state, substr($stream, $i, 1)));
}
is($status, 'done', 'parser handles one byte at a time');
is($state->{pcm}, "\1\0\2\0", 'audio payload collected');
my $error = $W->newParser;
is($W->collect($error, $W->feed($error, qq({"type": "error", "data": {"text": "no voice"}}\n))), 'error', 'server error reported');
is($error->{error}, 'no voice', 'server error text');
like($W->synthesizeEvent('Hi', 'en_US-ryan-high'), qr/^\{"data_length":\d+,"type":"synthesize"\}\n\{"text":"Hi","voice":\{"name":"en_US-ryan-high"\}\}$/, 'synthesize event');

sub body { my ($file) = @_; open(my $fh, '<', $file) or die $!; local $/; my $t = <$fh>; $t =~ s/^package .*?;\n//; $t =~ s/^# Keep in step.*\n//m; return $t }
is(body("$FindBin::Bin/../TodayAlarm/Wyoming.pm"), body("$FindBin::Bin/../WeatherAlerts/Wyoming.pm"), 'both plugins carry the same Wyoming client');

done_testing();
