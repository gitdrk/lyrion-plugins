#!/usr/bin/env python3
"""Record Weather Alerts' fallback phrases through a Wyoming Piper server.

  python tools/make_clips.py <host:port> [voice]

The default voice, en_US-ljspeech-medium, is trained on the public-domain
LJ Speech dataset, so the recordings can ship with the plugin.
"""
import json, pathlib, socket, sys, wave

OFFICIALS = "Follow instructions from local officials."

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
    "EVI": "Evacuation Immediate. Leave now if you are in the affected area.",
    "SPW": "Shelter In Place Warning. Go indoors and stay there.",
    "CDW": f"Civil Danger Warning. {OFFICIALS}",
    "CEM": f"Civil Emergency Message. {OFFICIALS}",
    "LAE": f"Local Area Emergency. {OFFICIALS}",
    "HMW": f"Hazardous Materials Warning. {OFFICIALS}",
    "NUW": f"Nuclear Power Plant Warning. {OFFICIALS}",
    "RHW": f"Radiological Hazard Warning. {OFFICIALS}",
    "LEW": f"Law Enforcement Warning. {OFFICIALS}",
    "FRW": "Fire Warning. Be ready to leave the area.",
    "EQW": "Earthquake Warning. Drop, cover and hold on.",
    "VOW": f"Volcano Warning. {OFFICIALS}",
    "CAE": "Child Abduction Emergency. Details are on the screen and in the Lyrion app.",
    "BLU": "Blue Alert. Details are on the screen and in the Lyrion app.",
    "OTHER": "An alert has been issued for your area.",
    "TEST": "This is a test of the NOAA Weather Alerts plugin. No action is needed.",
}


def read_event(f):
    header = json.loads(f.readline())
    data = header.get("data") or {}
    if header.get("data_length"):
        data.update(json.loads(f.read(header["data_length"])))
    payload = f.read(header["payload_length"]) if header.get("payload_length") else b""
    return header["type"], data, payload


def speak(host, port, voice, text):
    with socket.create_connection((host, port), timeout=30) as s:
        body = json.dumps({"text": text, "voice": {"name": voice}}).encode()
        s.sendall(json.dumps({"type": "synthesize", "data_length": len(body)}).encode() + b"\n" + body)
        f = s.makefile("rb")
        fmt, pcm = None, b""
        while True:
            kind, data, payload = read_event(f)
            if kind == "audio-start":
                fmt = data
            elif kind == "audio-chunk":
                fmt = fmt or data
                pcm += payload
            elif kind == "audio-stop":
                return fmt, pcm
            elif kind == "error":
                raise SystemExit(f"Speech server error: {data}")


host, port = sys.argv[1].rsplit(":", 1)
voice = sys.argv[2] if len(sys.argv) > 2 else "en_US-ljspeech-medium"
target = pathlib.Path(__file__).resolve().parent.parent / "WeatherAlerts" / "Clips"
target.mkdir(exist_ok=True)

for code, text in PHRASES.items():
    fmt, pcm = speak(host, int(port), voice, text)
    if (fmt["rate"], fmt["width"], fmt["channels"]) != (22050, 2, 1):
        raise SystemExit(f"Expected 22050 Hz mono 16-bit audio, got {fmt}")
    with wave.open(str(target / f"{code}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(pcm)
    print(code, round(len(pcm) / 44100, 1))
