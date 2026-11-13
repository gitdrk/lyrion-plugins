#!/usr/bin/env python3
"""Record Today Alarm's fallback phrases through a Wyoming Piper server.

  python tools/make_today_clips.py <host:port> [voice]

The default voice, en_US-ljspeech-medium, is trained on the public-domain
LJ Speech dataset, so the recordings can ship with the plugin.
"""
import json, pathlib, socket, sys, wave

DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
COUNTS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

PHRASES = {
    "greet_morning": "Good morning.",
    "greet_afternoon": "Good afternoon.",
    "greet_evening": "Good evening.",
    **{f"day_{i}": f"It's {day}." for i, day in enumerate(DAYS)},
    "count_0": "Nothing on your calendar today.",
    "count_1": "You have one event today.",
    **{f"count_{i + 1}": f"You have {word} events today." for i, word in enumerate(COUNTS) if i > 0},
    "count_many": "You have more than ten events today.",
    "details": "Your plan is on the screen and in the Lyrion app.",
    "headlines": "Today's headlines are on the screen and in the Lyrion app.",
    "problem": "One of your calendars couldn't be loaded.",
    "goodbye": "Have a good day.",
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
target = pathlib.Path(__file__).resolve().parent.parent / "TodayAlarm" / "Clips"
target.mkdir(exist_ok=True)

for name, text in PHRASES.items():
    fmt, pcm = speak(host, int(port), voice, text)
    if (fmt["rate"], fmt["width"], fmt["channels"]) != (22050, 2, 1):
        raise SystemExit(f"Expected 22050 Hz mono 16-bit audio, got {fmt}")
    with wave.open(str(target / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(pcm)
    print(name, round(len(pcm) / 44100, 1))
