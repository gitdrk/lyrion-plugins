#!/usr/bin/env python3
"""Build a zip for every plugin folder, then write the combined repo.xml.

Each plugin needs a release tagged <Folder>-v<version> with its zip attached.
"""
import hashlib, pathlib, re, subprocess, time, zipfile

GITHUB = "https://github.com/gitdrk/lyrion-plugins"
DETAILS = {
    "WeatherAlerts": {
        "title": "NOAA Weather Alerts (USA)",
        "desc": "Plays U.S. National Weather Service alerts on your Squeezeboxes, then restores what was playing. "
                "Unofficial, and not affiliated with NOAA.",
        "category": "misc",
        "minTarget": "9.0",
    },
}


def build(folder):
    source = pathlib.Path(folder)
    version = re.search(r"<version>(.+?)</version>", (source / "install.xml").read_text()).group(1)
    target = pathlib.Path(f"{folder}-{version}.zip")

    tracked = subprocess.run(["git", "ls-files", source.as_posix()], capture_output=True, text=True, check=True)
    files = [pathlib.Path(name) for name in tracked.stdout.splitlines()]

    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            if not path.is_file():
                raise SystemExit(f"Cannot read {path}. Is the folder path too long?")
            # A real date matters: Lyrion only reloads strings when file times change.
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), time.localtime()[:6])
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, path.read_bytes())

    sha = hashlib.sha1(target.read_bytes()).hexdigest()
    print(target, sha)
    return version, target.name, sha


def entry(folder):
    version, zip_name, sha = build(folder)
    d = DETAILS[folder]
    return f"""    <plugin name="{folder}" version="{version}" minTarget="{d['minTarget']}" maxTarget="*">
      <title lang="EN">{d['title']}</title>
      <desc lang="EN">{d['desc']}</desc>
      <creator>gitdrk</creator>
      <category>{d['category']}</category>
      <link>{GITHUB}</link>
      <url>{GITHUB}/releases/download/{folder}-v{version}/{zip_name}</url>
      <sha>{sha}</sha>
    </plugin>
"""


plugins = "".join(entry(folder) for folder in DETAILS)
pathlib.Path("repo.xml").write_text(f"""<?xml version="1.0"?>
<extensions>
  <details>
    <title lang="EN">gitdrk Lyrion Plugins</title>
  </details>
  <plugins>
{plugins}  </plugins>
</extensions>
""", newline="\n")
