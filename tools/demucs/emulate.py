# Emulates, step by step, what StemSeparator.swift does, and checks it against demucs.
import math, numpy as np, torch
from wrap import *
N, HOP, FQ_, SEG = 4096, 1024, 2048, L
WIN = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)

def reflect(x, left, right):
    n = len(x)
    return np.concatenate([x[1:left+1][::-1], x, x[n-1-right:n-1][::-1]])

def stft(x):  # one channel, SEG samples -> (FQ, T) complex
    le = math.ceil(len(x) / HOP)
    p = HOP // 2 * 3
    y = reflect(x, p, p + le * HOP - len(x))
    y = reflect(y, N // 2, N // 2)
    out = np.zeros((FQ_, le), complex)
    for t in range(le):
        f = y[(t + 2) * HOP:(t + 2) * HOP + N] * WIN
        out[:, t] = np.fft.fft(f)[:FQ_] / math.sqrt(N)
    return out

def istft(z, length):  # (FQ, T) -> length samples
    le = z.shape[1]; p = HOP // 2 * 3
    frames = le + 4
    buf = np.zeros(N + HOP * (frames - 1)); env = np.zeros_like(buf)
    for t in range(frames):
        env[t * HOP:t * HOP + N] += WIN ** 2
        if 2 <= t < 2 + le:
            full = np.zeros(N, complex); full[:FQ_] = z[:, t - 2]
            full[0] = full[0].real
            full[N - FQ_ + 1:] = np.conj(full[1:FQ_][::-1])  # bins 2049.. mirror 2047..1 ; Nyquist (2048) stays 0
            f = np.fft.ifft(full).real * N / math.sqrt(N)   # unscaled IDFT / sqrt(N)
            buf[t * HOP:t * HOP + N] += f * WIN
    start = N // 2 + p
    return buf[start:start + length] / env[start:start + length]

def separate(m, core, mix):  # mix (2, n) float -> (4, 2, n)
    ref = mix.mean(0); mu, sd = ref.mean(), ref.std(ddof=1)
    mix = (mix - mu) / sd
    n = mix.shape[1]; stride = int(0.75 * SEG)
    w = np.concatenate([np.arange(1, SEG // 2 + 1), np.arange(SEG - SEG // 2, 0, -1)]).astype(float); w /= w.max()
    out = np.zeros((4, 2, n)); sw = np.zeros(n)
    for off in range(0, n, stride):
        cl = min(SEG, n - off); delta = SEG - cl; start = off - delta // 2
        chunk = np.zeros((2, SEG))
        a, b = max(0, start), min(n, start + SEG); chunk[:, a - start:b - start] = mix[:, a:b]
        spec = np.zeros((4, FQ_, T))
        for c in range(2):
            z = stft(chunk[c]); spec[2 * c] = z.real; spec[2 * c + 1] = z.imag
        sm, ss = spec.mean(), spec.std(ddof=1); cm, cs = chunk.mean(), chunk.std(ddof=1)
        with torch.no_grad():
            so, wv = core(torch.tensor((chunk - cm) / (1e-5 + cs), dtype=torch.float32)[None],
                          torch.tensor((spec - sm) / (1e-5 + ss), dtype=torch.float32)[None])
        so = so[0].double().numpy() * ss + sm; wv = wv[0].double().numpy() * cs + cm
        res = np.zeros((4, 2, SEG))
        for s in range(4):
            for c in range(2):
                res[s, c] = istft(so[s, 2 * c] + 1j * so[s, 2 * c + 1], SEG) + wv[s, c]
        piece = res[..., delta // 2:delta // 2 + cl]
        out[..., off:off + cl] += w[:cl] * piece; sw[off:off + cl] += w[:cl]
    return out / sw * sd + mu

if __name__ == "__main__":
    torch.backends.mha.set_fastpath_enabled(False)
    m = load(); core = Core(m).eval()
    rng = np.random.default_rng(1)
    x = rng.standard_normal(SEG) * 0.1
    z = stft(x); zt = m._spec(torch.tensor(x)[None, None])[0, 0].numpy()
    print("stft err", np.abs(z - zt).max(), "max", np.abs(zt).max())
    zz = rng.standard_normal((FQ_, T)) + 1j * rng.standard_normal((FQ_, T))
    a = istft(zz, SEG); b = m._ispec(torch.tensor(zz)[None, None], SEG)[0, 0].numpy()
    print("istft err", np.abs(a - b).max(), "max", np.abs(b).max())
    from demucs.apply import apply_model
    mix = rng.standard_normal((2, 500000)) * 0.1
    mix[:, 100000:110000] *= 5
    ours = separate(m, core, mix)
    with torch.no_grad():
        theirs = apply_model(m, torch.tensor(mix, dtype=torch.float32)[None], shifts=0, split=True, overlap=0.25)[0].numpy()
    ref = mix.mean(0)
    with torch.no_grad():
        theirs = apply_model(m, torch.tensor((mix - ref.mean()) / ref.std(), dtype=torch.float32)[None], shifts=0, split=True, overlap=0.25)[0].numpy() * ref.std() + ref.mean()
    print("separate err", np.abs(ours - theirs).max(), "max", np.abs(theirs).max())
