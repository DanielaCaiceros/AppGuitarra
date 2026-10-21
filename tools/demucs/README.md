# HTDemucs → Core ML

The app splits imported songs into drums, bass, guitar & others and vocals with
[HTDemucs](https://github.com/facebookresearch/demucs) (Meta, MIT license),
converted to `AppGuitarra/Resources/HTDemucs.mlpackage`.

The model file is ~90 MB, so it is **not in git** (see `.gitignore`). Without it
the app still builds; "Split into tracks" is just disabled.

## Rebuild the model

1. Download the weights (84 MB) into this repo's root folder:
   https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th
2. Install: `pip install torch coremltools demucs` (tested: torch 2.14, coremltools 9.0).
3. Run from the repo root:
   ```
   DEMUCS_WEIGHTS=955717e8-8726e21a.th python3 tools/demucs/convert.py
   mv HTDemucs.mlpackage AppGuitarra/Resources/
   ```

coremltools 9.0 needs one patch (`_cast` in `frontend/torch/ops.py` fails on a
1-element array): replace `dtype(x.val)` with
`dtype(np.asarray(x.val).reshape(-1)[0])`.

## What is in the model and what is in Swift

- `wrap.py`: `Core` is HTDemucs without its STFT/iSTFT and without the input
  normalization (big reductions that would run in Float16). Checked equal to
  demucs' own forward pass.
- `convert.py`: traces `Core` and converts it (iOS 17, Float16 except
  reductions and normalizations, which stay Float32). Inputs: `mix` (1, 2, 343980)
  and `spec` (1, 4, 2048, 336), both normalized. Outputs: `specOut` (1, 4, 4, 2048, 336)
  and `wave` (1, 4, 2, 343980), before de-normalization. Sources: drums, bass, other, vocals.
- `emulate.py`: numpy version of exactly what `Songs/StemSeparator.swift` does
  (reflect padding, STFT, iSTFT, 7.8 s segments with 25 % overlap and triangle
  weights). Matches `demucs.apply.apply_model` to 1e-6.
- `fixtures.py`: writes `AppGuitarraTests/separator_fixture.json` for
  `StemSeparatorTests` (STFT points and a 10 s separation from torch, Float32).
