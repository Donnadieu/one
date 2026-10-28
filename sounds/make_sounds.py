# Makes One's helper sounds (organ swell = chime-done, organ question = chime-yes) at One's audio-line format (24 kHz mono).
# OUT=<dir> uv run --with numpy --with scipy python sounds/make_sounds.py
import numpy as np, subprocess, os, json
from scipy.signal import butter, sosfiltfilt, fftconvolve

SR = 24000
rng = np.random.default_rng(11)
OUT = os.environ.get("OUT", ".")
TMP = os.path.dirname(os.path.abspath(__file__))


def t(d):
    return np.arange(int(d * SR)) / SR


def lp(x, fc):
    return sosfiltfilt(butter(4, fc, fs=SR, output="sos"), x)


def bp(x, lo, hi):
    return sosfiltfilt(butter(3, [lo, hi], btype="band", fs=SR, output="sos"), x)


def place(buf, s, at):
    s = s.copy()
    k = min(len(s), int(0.02 * SR))
    s[-k:] *= np.linspace(1, 0, k)
    i = int(at * SR)
    end = min(len(buf), i + len(s))
    buf[i:end] += s[: end - i]


def adsr(n, a, decay):
    x = np.arange(n) / SR
    att = np.clip(x / a, 0, 1)
    return (0.5 - 0.5 * np.cos(np.pi * att)) * np.exp(-np.clip(x - a, 0, None) / decay)


def swell(n, peak_at, fall):
    x = np.arange(n) / SR
    up = np.clip(x / peak_at, 0, 1) ** 2
    return np.where(x < peak_at, up, np.exp(-(x - peak_at) / fall))


def space(x, size=2.2, mix=0.45, dark=4000):
    # a big, dark hall: the "vastness" of space
    n = int(size * SR)
    ir = rng.standard_normal(n) * np.exp(-np.arange(n) / SR / (size / 5))
    ir = lp(ir, dark)
    ir[: int(0.012 * SR)] = 0  # tiny pre-delay
    ir /= np.sqrt(np.sum(ir**2))
    wet = fftconvolve(x, ir)[: len(x)]
    return (1 - mix) * x + mix * wet


def organ(f, n, stops=((1, 1), (2, 0.5), (3, 0.18), (4, 0.22), (8, 0.06))):
    tt = np.arange(n) / SR
    s = np.zeros(n)
    for r, a in stops:
        if f * r < 9000:
            s += a * np.sin(2 * np.pi * f * r * tt + r)
    return s


# 1. Organ swell: a soft pipe-organ chord breathing in and out (Zimmer's Interstellar organ).
def organ_swell():
    d = 1.4
    n = int(d * SR)
    s = organ(220.0, n) + 0.7 * organ(329.63, n) + 0.45 * organ(440.0, n) * 0.8 + 0.35 * organ(554.37, n)  # A, E, A, C#
    s *= swell(n, 0.45, 0.32)
    return space(s, 2.4, 0.5)


# 2. Ticking clock into the void: two soft ticks, then a low organ note blooms (the Miller's planet clock).
def tick_bloom():
    d = 1.4
    n = int(d * SR)
    buf = np.zeros(n)
    for at in (0.05, 0.33):
        k = int(0.03 * SR)
        click = bp(rng.standard_normal(k), 1800, 3200) * np.exp(-np.arange(k) / SR / 0.006) * np.clip(np.arange(k) / (0.002 * SR), 0, 1)
        place(buf, click * 0.45, at)
    m = int(1.0 * SR)
    note = (organ(146.83, m) + 0.6 * organ(220.0, m)) * swell(m, 0.3, 0.28)  # D3 + A3, an open fifth
    place(buf, 0.6 * note, 0.41)
    return space(buf, 2.2, 0.45)


# 3. Sonar ping: one clear ping that echoes away into deep space.
def sonar_ping():
    d = 1.4
    n = int(d * SR)
    buf = np.zeros(n)
    m = int(0.5 * SR)
    tt = np.arange(m) / SR
    ping = (np.sin(2 * np.pi * 1046.5 * tt) + 0.2 * np.sin(2 * np.pi * 2093 * tt)) * adsr(m, 0.006, 0.09)
    for i, at in enumerate((0.0, 0.32, 0.64, 0.96)):
        place(buf, ping * (0.55**i), at)  # echoes, each softer
    return space(buf, 2.0, 0.4, dark=3000)


# 4. Pulsar: three soft radio-telescope pulses, like a real pulsar recording, fading.
def pulsar():
    d = 1.2
    n = int(d * SR)
    buf = np.zeros(n)
    tt = t(d)
    carrier = np.sin(2 * np.pi * 392.0 * tt) + 0.5 * np.sin(2 * np.pi * 784.0 * tt)
    radio = bp(rng.standard_normal(n), 300, 2500) * 0.25
    gate = np.zeros(n)
    for i, at in enumerate((0.0, 0.25, 0.5)):
        k = int(0.18 * SR)
        place(gate, np.sin(np.pi * np.arange(k) / k) ** 3 * (0.8**i), at)
    s = (carrier + radio) * gate
    return space(s, 2.0, 0.45)


# 5. Star shimmer: a cluster of slowly beating high tones that glitters, then dissolves.
def star_shimmer():
    d = 1.3
    n = int(d * SR)
    tt = t(d)
    s = np.zeros(n)
    for f in (1318.5, 1320.9, 1975.5, 1978.0, 2637.0, 2959.9):
        s += np.sin(2 * np.pi * f * tt + rng.uniform(0, 6.28)) * (1 + 0.6 * np.sin(2 * np.pi * rng.uniform(5, 11) * tt))
    s += 1.4 * np.sin(2 * np.pi * 659.25 * tt)  # warm floor under it
    s *= swell(n, 0.35, 0.3)
    return space(s, 2.5, 0.55, dark=6000)


# 6. Gargantua pass: a deep swell that bends down as it passes, like a ship sliding past a planet.
def gravity_pass():
    d = 1.3
    n = int(d * SR)
    tt = t(d)
    f = 220 * 2 ** (-0.35 * np.clip(tt / d, 0, 1) ** 1.5)  # slides down ~4 semitones
    ph = 2 * np.pi * np.cumsum(f) / SR
    s = np.sin(ph) + 0.5 * np.sin(2 * ph) + 0.25 * np.sin(3 * ph) + 0.12 * np.sin(4 * ph)
    air = bp(rng.standard_normal(n), 200, 1200) * 0.35
    s = (s + air) * swell(n, 0.5, 0.3)
    return space(s, 2.4, 0.5, dark=2500)


# 7. Deep-space beacon: a calm two-tone transmission with a breath of radio static.
def beacon():
    d = 1.2
    n = int(d * SR)
    buf = np.zeros(n)
    def tone(f, dur):
        m = int(dur * SR)
        tt = np.arange(m) / SR
        return (np.sin(2 * np.pi * f * tt) + 0.15 * np.sin(2 * np.pi * 3 * f * tt)) * adsr(m, 0.03, 0.18)
    place(buf, tone(880.0, 0.4), 0.0)
    place(buf, tone(1174.66, 0.55), 0.18)  # A5 -> D6
    static = bp(rng.standard_normal(n), 1500, 4000) * 0.04 * swell(n, 0.1, 0.4)
    return space(buf + static, 1.8, 0.4)


# Needs your yes: the organ asks a question. Two rising organ chords, the second held and brighter.
def needs_yes():
    d = 1.4
    n = int(d * SR)
    buf = np.zeros(n)
    m1 = int(0.5 * SR)
    a = (organ(293.66, m1) + 0.7 * organ(440.0, m1)) * swell(m1, 0.08, 0.2)  # D4 + A4
    m2 = int(1.0 * SR)
    b = (organ(392.0, m2) + 0.7 * organ(587.33, m2) + 0.4 * organ(783.99, m2)) * swell(m2, 0.08, 0.3)  # G4 + D5 + G5
    place(buf, a, 0.0)
    place(buf, b, 0.3)
    return space(buf, 2.2, 0.4)


def finish(x, mean_db, peak_db=-6.0, fade_in=0.03, lead=0.02):
    x = x - np.mean(x)
    fi = int(fade_in * SR)
    x[:fi] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(fi) / fi)
    fo = int(0.15 * SR)
    x[-fo:] *= np.linspace(1, 0, fo) ** 2
    a = np.abs(x)
    act = x[a > a.max() * 0.01]
    g = 10 ** (mean_db / 20) / np.sqrt(np.mean(act**2))
    g = min(g, 10 ** (peak_db / 20) / a.max())
    return np.concatenate([np.zeros(int(lead * SR)), x * g])


def write(x, name):
    raw = os.path.join(TMP, "tmp.f32")
    x.astype("<f4").tofile(raw)
    mp3 = os.path.join(OUT, name + ".mp3")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "f32le", "-ar", str(SR), "-ac", "1", "-i", raw,
                    "-c:a", "libmp3lame", "-b:a", "128k", mp3], check=True)
    os.remove(raw)
    return mp3


sounds = [
    ("1 - organ swell", organ_swell),
    ("2 - clock tick and bloom", tick_bloom),
    ("3 - sonar ping", sonar_ping),
    ("4 - pulsar", pulsar),
    ("5 - star shimmer", star_shimmer),
    ("6 - gravity pass", gravity_pass),
    ("7 - deep space beacon", beacon),
]
made, row = [], []
for label, fn in sounds:
    x = fn()
    nrm = finish(x.copy(), -27)
    made.append(write(nrm, f"2026-10-28 Space sound {label}"))
    made.append(write(finish(x.copy(), -36), f"2026-10-28 Space sound {label} (quiet)"))
    row += [nrm, np.zeros(int(0.6 * SR))]
y = needs_yes()
ny = finish(y.copy(), -23, peak_db=-4.5)
made.append(write(ny, "2026-10-28 Space sound - needs your yes"))
made.append(write(finish(y.copy(), -32), "2026-10-28 Space sound - needs your yes (quiet)"))
row += [np.zeros(int(0.3 * SR)), ny]
made.append(write(np.concatenate(row), "2026-10-28 Space sounds - all in a row"))
print(json.dumps(made, indent=1))
