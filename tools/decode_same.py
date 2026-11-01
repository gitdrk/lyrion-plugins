#!/usr/bin/env python3
"""Decode SAME bursts from a 22050 Hz mono WAV by measuring tone energy per bit."""
import cmath, math, struct, sys, wave

RATE, BAUD, MARK, SPACE = 22050, 520 + 5 / 6, 2083 + 1 / 3, 1562.5
PER_BIT = RATE / BAUD


def energy(samples, frequency):
    step = 2 * math.pi * frequency / RATE
    return abs(sum(s * cmath.exp(-1j * step * i) for i, s in enumerate(samples)))


def bit_at(samples, position):
    start = int(position + 0.5)
    chunk = samples[start:start + int(PER_BIT)]
    return 1 if energy(chunk, MARK) > energy(chunk, SPACE) else 0


def read_byte(samples, position):
    value = sum(bit_at(samples, position + i * PER_BIT) << i for i in range(8))
    return value, position + 8 * PER_BIT


def find_signal(samples, start):
    position = start
    while position < len(samples) - 2000:
        if max(abs(s) for s in samples[position:position + 40]) > 3000:
            for offset in range(0, 90):
                candidate = position + offset
                if read_byte(samples, candidate)[0] == 0xAB and read_byte(samples, candidate + 8 * PER_BIT)[0] == 0xAB:
                    return candidate
            position += RATE // 4  # not SAME, so probably the attention tone
        position += 40
    return None


def decode(path):
    with wave.open(path) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (RATE, 1, 2)
        samples = struct.unpack(f"<{w.getnframes()}h", w.readframes(w.getnframes()))

    messages, cursor = [], 0
    while True:
        position = find_signal(samples, cursor)
        if position is None:
            return messages
        while read_byte(samples, position)[0] == 0xAB:
            position += 8 * PER_BIT
        text = ""
        while True:
            value, position = read_byte(samples, position)
            if not 32 <= value < 127:
                break
            text += chr(value)
        messages.append(text)
        cursor = int(position) + RATE // 2


for message in decode(sys.argv[1]):
    print(message)
