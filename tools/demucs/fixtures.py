import json, math, numpy as np, torch
from emulate import *
torch.backends.mha.set_fastpath_enabled(False)
SR = 44100

def stft_signal(n):  # must match StemSeparatorTests.stftSignal
    i = np.arange(n, dtype=np.float64); t = i / SR
    a = 0.3 * np.sin(2 * np.pi * 220 * t) + 0.1 * np.sin(2 * np.pi * 3150 * t) * np.cos(2 * np.pi * 0.5 * t)
    b = 0.2 * np.sin(2 * np.pi * 330 * t + 1)
    return np.stack([a, b]).astype(np.float32).astype(np.float64)

def song_signal(n):  # must match StemSeparatorTests.songSignal
    t = np.arange(n, dtype=np.float64) / SR
    other = 0.12 * sum(np.sin(2 * np.pi * f * t) for f in (196.0, 246.94, 293.66, 392.0))
    bass = 0.25 * np.sin(2 * np.pi * 98 * t)
    u = np.mod(t, 0.5)
    drum = 0.6 * np.exp(-30 * u) * np.sin(2 * np.pi * 80 * u)
    return np.stack([other + bass + drum, 0.8 * other + bass + drum]).astype(np.float32).astype(np.float64)

x = stft_signal(SEG)
points = []
for c in range(2):
    z = stft(x[c])
    for k, (fbin, frame) in enumerate([(20, 0), (20, 100), (30, 335), (292, 50), (5, 200), (1000, 10), (2047, 300), (0, 77)]):
        points.append({"channel": c, "bin": fbin, "frame": frame, "re": float(z[fbin, frame].real), "im": float(z[fbin, frame].imag)})

m = load(); core = Core(m).eval()
n = 10 * SR
mix = song_signal(n)
out = separate(m, core, mix)
idx = list(range(1000, n, n // 256))[:256]
stems = []
for s, name in enumerate(m.sources):
    stems.append({"name": name, "rms": [float(np.sqrt((out[s, c] ** 2).mean())) for c in range(2)],
                  "samples": [[float(out[s, c, j]) for j in idx] for c in range(2)]})
json.dump({"stft": points, "song": {"length": n, "indices": idx, "stems": stems}}, open("separator_fixture.json", "w"))
print([ (s["name"], [round(r, 4) for r in s["rms"]]) for s in stems])
