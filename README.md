# NOAA Weather Alerts (USA) for Lyrion

A Lyrion Music Server plugin that watches U.S. National Weather Service alerts for your county, interrupts your Squeezeboxes with SAME-style tones and a spoken message, then restores what each player was doing. Unofficial, and not affiliated with NOAA.

**This is not a life-safety system.** It needs power, your network and the internet. Keep a battery-backed NOAA Weather Radio as your primary warning.

## Install

1. In Lyrion, open Settings, then Plugins.
2. Under Additional Repositories, add this URL and save:

   `https://raw.githubusercontent.com/gitdrk/lyrion-weather-alerts/main/repo.xml`

3. Enable NOAA Weather Alerts (USA) in the plugin list and restart when asked.

## Set up

Open the plugin's settings and enter your alert zones. To find them, open this address with your latitude and longitude, then use the codes at the end of the `county` and `forecastZone` values:

`https://api.weather.gov/points/38.2856,-85.8241`

Enter both, such as `INC043,INZ091`. Warnings are usually issued by county and winter alerts by forecast zone.

Then choose what each alert type does, pick your players, and use **Send test alert**.

## What each player gets back

| Before the alert | After the alert |
| --- | --- |
| Local track playing or paused | Same track, position and state |
| Stopped or off | Same state and queue |
| Internet radio | Same station, at the live point |
| Podcast or streaming service | Same track, seeking if the service allows it |

Synced players are treated as one group and stay synced. Pressing Stop ends the alert on that player only.

## Better speech (optional)

Without a speech server, the plugin plays a short recorded phrase such as "Tornado Warning". To hear the full alert text, run a [Piper](https://github.com/OHF-Voice/piper1-gpl) HTTP server that accepts `POST` JSON `{"text": "..."}` and returns a mono WAV, then enter its URL in the settings.

## Commands

These run through Lyrion's CLI or JSON-RPC API:

| Command | Effect |
| --- | --- |
| `weatheralerts test player:<ids>` | Plays a test alert at the test volume |
| `weatheralerts simulate code:TOR player:<ids>` | Plays an alert type at the test volume |
| `weatheralerts stop` | Ends the current alert |
| `weatheralerts status` | Reports feed and takeover state |

## Build

```bash
perl t/pure.t
python tools/make_clips.py
python build.py
```

Build from a short folder path. Windows drops files from very long ones, and the build stops if that happens.

## Credits

Fallback speech clips were generated with Piper and its `en_US-ljspeech-medium` voice, which is trained on the public-domain LJ Speech dataset.
