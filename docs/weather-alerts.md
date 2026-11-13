# NOAA Weather Alerts (USA) for Lyrion

A Lyrion Music Server plugin that watches U.S. National Weather Service alerts for your county, interrupts your Squeezeboxes with an alert tone and a spoken message, then restores what each player was doing. Unofficial, and not affiliated with NOAA.

**This is not a life-safety system.** It needs power, your network and the internet. Keep a battery-backed NOAA Weather Radio as your primary warning.

## Install

Follow the steps in the [main README](../README.md).

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

## Full spoken alerts (optional)

Without a speech server, the plugin plays a short recorded phrase such as "Tornado Warning". To hear the full alert text, enter a speech server in the settings and pick a voice:

- A Wyoming Piper server as `host:port`, the kind Home Assistant uses.
- Or the URL of a [Piper](https://github.com/OHF-Voice/piper1-gpl) HTTP server that accepts `POST` JSON `{"text": "..."}` and returns a mono WAV.

If the server can't be reached, the recorded phrase plays instead.

## Commands

These run through Lyrion's CLI or JSON-RPC API:

| Command | Effect |
| --- | --- |
| `weatheralerts test player:<ids>` | Plays a test alert at the test volume |
| `weatheralerts simulate code:TOR player:<ids>` | Plays an alert type at the test volume |
| `weatheralerts stop` | Ends the current alert |
| `weatheralerts status` | Reports feed and takeover state |

## Credits

Fallback speech clips were generated with Piper and its `en_US-ljspeech-medium` voice, which is trained on the public-domain LJ Speech dataset.
