#!/usr/bin/env python3
"""Build the plugin zip and repo.xml. Run this, then attach the zip to a release."""
import hashlib, pathlib, re, subprocess, zipfile

GITHUB = "https://github.com/gitdrk/lyrion-weather-alerts"
source = pathlib.Path("WeatherAlerts")
version = re.search(r"<version>(.+?)</version>", (source / "install.xml").read_text()).group(1)
target = pathlib.Path(f"WeatherAlerts-{version}.zip")

tracked = subprocess.run(["git", "ls-files", source.as_posix()], capture_output=True, text=True, check=True)
files = [pathlib.Path(name) for name in tracked.stdout.splitlines()]

with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in files:
        if not path.is_file():
            raise SystemExit(f"Cannot read {path}. Is the folder path too long?")
        info = zipfile.ZipInfo(path.relative_to(source).as_posix())
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, path.read_bytes())

sha = hashlib.sha1(target.read_bytes()).hexdigest()
pathlib.Path("repo.xml").write_text(f"""<?xml version="1.0"?>
<extensions>
  <details>
    <title lang="EN">NOAA Weather Alerts (USA)</title>
  </details>
  <plugins>
    <plugin name="WeatherAlerts" version="{version}" minTarget="9.0" maxTarget="*">
      <title lang="EN">NOAA Weather Alerts (USA)</title>
      <desc lang="EN">Plays U.S. National Weather Service alerts on your Squeezeboxes, then restores what was playing. Unofficial, and not affiliated with NOAA.</desc>
      <creator>gitdrk</creator>
      <category>misc</category>
      <link>{GITHUB}</link>
      <url>{GITHUB}/releases/download/v{version}/{target.name}</url>
      <sha>{sha}</sha>
    </plugin>
  </plugins>
</extensions>
""", newline="\n")
print(target, sha)
