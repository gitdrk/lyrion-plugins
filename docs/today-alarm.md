# Today Alarm

After you turn off an alarm, Today Alarm plays a short briefing on that player: today's calendar events, then news headlines. It's spoken when a speech server is set, and shown on the player's screen and in Material either way.

## Set an alarm

Use Lyrion's normal alarm settings. Any sound works, including favorites and radio stations. The plugin also adds **Today Alarm: Morning Chime** to the alarm sound list. If a stream fails, Lyrion plays its own backup buzzer.

## When the briefing plays

| The alarm ends by | Briefing |
| --- | --- |
| Stop or Pause | Plays |
| The power button | Skipped, unless you turn it on in settings |
| Timing out with nobody there | Skipped, unless you turn it on in settings |
| Snooze | Waits for the final stop |

## Calendars

The settings page has a field each for Google, Outlook and iCloud. Each takes one or more private iCal links, one per line. Events from all of them are merged into one list, and an event that appears in two calendars is read once.

| Calendar | Where to get the link |
| --- | --- |
| Google | On the web, open the calendar's Settings and sharing, then copy **Secret address in iCal format** under Integrate calendar |
| Outlook | In Outlook on the web, open Settings, Calendar, Shared calendars, then Publish a calendar with **Can view all details**, and copy the ICS link |
| iCloud | In the Calendar app, turn on **Public Calendar** for the calendar and copy its share link |

Anyone with one of these links can read that calendar. The plugin keeps them in Lyrion's settings, shows them shortened after saving, and never writes them to the log.

Google and Outlook can take hours to update these links, so a late change may miss the next briefing.

## News feeds

Add RSS or Atom feeds one per line, most important first. Add a name after a bar to have it read out:

```
https://example.com/rss | Local news
```

Feeds take turns, newest headline first, up to the per-feed and total limits. Only titles are read.

## Speech

Enter a Wyoming Piper server as `host:port`, the same kind Home Assistant uses, then pick a voice. Without one, the briefing is a chime plus on-screen text, and players without a screen hear only the chime.

## Commands

| Command | Effect |
| --- | --- |
| `todayalarm brief player:<id>` | Plays the briefing now |
| `todayalarm refresh` | Downloads calendars and feeds now |
| `todayalarm status` | Reports sources, speech and the current briefing text |
