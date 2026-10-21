import math, os, torch, torch.nn as nn
from einops import rearrange
from demucs.states import load_model
from demucs.htdemucs import pad1d
from demucs.spec import spectro, ispectro

L = 343980; HL = 1024; FQ = 2048; T = math.ceil(L / HL)  # 336

def load():
    pkg = torch.load(os.environ.get("DEMUCS_WEIGHTS", "955717e8-8726e21a.th"), map_location="cpu", weights_only=False)
    m = load_model(pkg); m.eval(); return m

class Core(nn.Module):
    """HTDemucs without STFT/iSTFT: (mix, spec) -> (spec per source, wave per source)."""
    def __init__(self, m):
        super().__init__(); self.m = m
    def forward(self, mix, spec):
        m = self.m; x = spec
        # Inputs come normalized (mean 0, std 1) and outputs leave un-denormalized:
        # those big reductions run in Float32 in Swift, not in Float16 here.
        B, C, Fq, Tt = x.shape
        xt = mix
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for idx, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1]); inject = None
            if idx < len(m.tencoder):
                lengths_t.append(xt.shape[-1]); tenc = m.tencoder[idx]; xt = tenc(xt)
                if not tenc.empty: saved_t.append(xt)
                else: inject = xt
            x = encode(x, inject)
            if idx == 0 and m.freq_emb is not None:
                frs = torch.arange(x.shape[-2])
                emb = m.freq_emb(frs).t()[None, :, :, None]  # broadcast, no 16 MB constant
                x = x + m.freq_emb_scale * emb
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = rearrange(x, "b c f t-> b c (f t)"); x = m.channel_upsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f); xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                x = rearrange(x, "b c f t-> b c (f t)"); x = m.channel_downsampler(x)
                x = rearrange(x, "b c (f t)-> b c f t", f=f); xt = m.channel_downsampler_t(xt)
        for idx, decode in enumerate(m.decoder):
            skip = saved.pop(-1); x, pre = decode(x, skip, lengths.pop(-1))
            offset = m.depth - len(m.tdecoder)
            if idx >= offset:
                tdec = m.tdecoder[idx - offset]; length_t = lengths_t.pop(-1)
                if tdec.empty:
                    pre = pre[:, :, 0]; xt, _ = tdec(pre, None, length_t)
                else:
                    skip = saved_t.pop(-1); xt, _ = tdec(xt, skip, length_t)
        S = len(m.sources)
        return x.view(B, S, -1, Fq, Tt), xt.view(B, S, -1, L)

def spec_cac(m, mix):
    z = m._spec(mix); return m._magnitude(z)

def finish(m, specout, wave):
    z = m._mask(None, specout); return m._ispec(z, L) + wave

def normalize(t, dims):
    mean = t.mean(dim=dims, keepdim=True); std = t.std(dim=dims, keepdim=True)
    return (t - mean) / (1e-5 + std), mean, std

def run(m, core, mix):
    """Full separation using Core: what the Swift code reproduces."""
    s = spec_cac(m, mix)
    sn, mean, std = normalize(s, (1, 2, 3)); mn, meant, stdt = normalize(mix, (1, 2))
    so, w = core(mn, sn)
    return finish(m, so * std[:, None] + mean[:, None], w * stdt[:, None] + meant[:, None])
