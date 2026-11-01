# Lyrion Plugins

Plugins for Lyrion Music Server, installed from one repository URL.

| Plugin | Folder | Docs |
| --- | --- | --- |
| NOAA Weather Alerts (USA) | `WeatherAlerts` | [Guide](docs/weather-alerts.md) |

## Install

1. In Lyrion, open Settings, then Plugins.
2. Under Additional Repositories, add this URL and save:

   `https://raw.githubusercontent.com/gitdrk/lyrion-plugins/main/repo.xml`

3. Enable the plugin you want in the plugin list and restart when asked.

## Build

```bash
perl t/pure.t
perl t/takeover.t
python build.py
```

`build.py` writes one zip per plugin and a combined `repo.xml`. Each zip goes on a release tagged `<Folder>-v<version>`, such as `WeatherAlerts-v1.0.1`.

Build from a short folder path. Windows drops files from very long ones, and the build stops if that happens.

## Branches

`main` holds released plugins. `sdr-radio` holds the SDR Radio plugin while it's in development.
