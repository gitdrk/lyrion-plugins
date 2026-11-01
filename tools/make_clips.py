#!/usr/bin/env python3
"""Generate the fallback speech clips with Piper.

  python tools/make_clips.py <piper executable> <voice .onnx file>
"""
import pathlib, subprocess, sys

PHRASES = {
    "TOR": "Tornado Warning. Take shelter now.",
    "SVR": "Severe Thunderstorm Warning. Move indoors now.",
    "FFW": "Flash Flood Warning. Move to higher ground now.",
    "EWW": "Extreme Wind Warning. Take shelter now.",
    "HUW": "Hurricane Warning. Follow your local evacuation orders.",
    "TSW": "Tsunami Warning. Move to high ground now.",
    "TOA": "Tornado Watch for your area. Be ready to take shelter.",
    "SVA": "Severe Thunderstorm Watch for your area.",
    "WSW": "Winter Storm Warning for your area.",
    "OTHER": "A weather alert has been issued for your area.",
    "TEST": "This is a test of the NOAA Weather Alerts plugin. No action is needed.",
}

piper, voice = sys.argv[1:3]
target = pathlib.Path(__file__).resolve().parent.parent / "WeatherAlerts" / "Clips"
target.mkdir(exist_ok=True)

for code, phrase in PHRASES.items():
    subprocess.run([piper, "--model", voice, "--output_file", str(target / f"{code}.wav")],
                   input=phrase.encode(), check=True, stderr=subprocess.DEVNULL)
    print(code)
