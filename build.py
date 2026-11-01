#!/usr/bin/env python3
"""Build the plugin zip and repo.xml. Run this, then attach the zip to a release."""
import hashlib, pathlib, re, zipfile

GITHUB = "https://github.com/gitdrk/lyrion-weather-alerts"
source = pathlib.Path("WeatherAlerts")
version = re.search(r"<version>(.+?)</version>", (source / "install.xml").read_text()).group(1)
target = pathlib.Path(f"WeatherAlerts-{version}.zip")

with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(source.rglob("*")):
        if path.is_file():
            info = zipfile.ZipInfo(path.relative_to(source).as_posix())
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())

sha = hashlib.sha1(target.read_bytes()).hexdigest()
pathlib.Path("repo.xml").write_text(f"""<?xml version="1.0"?>
<extensions>
  <details>
    <title lang="EN">Lyrion Weather Alerts</title>
  </details>
  <plugins>
    <plugin name="WeatherAlerts" version="{version}" minTarget="9.0" maxTarget="*">
      <title lang="EN">Weather Alerts</title>
      <desc lang="EN">Plays National Weather Service alerts on your Squeezeboxes, then restores what was playing.</desc>
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
