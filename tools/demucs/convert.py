import torch, coremltools as ct; from wrap import *
torch.backends.mha.set_fastpath_enabled(False)
m = load(); core = Core(m).eval()
mix = torch.randn(1, 2, L); spec = torch.randn(1, 4, FQ, T)
with torch.no_grad():
    traced = torch.jit.trace(core, (mix, spec), check_trace=False)
# Reductions and normalizations stay in Float32; the rest runs in Float16.
KEEP32 = {"reduce_mean", "reduce_sum", "reduce_sum_square", "layer_norm", "instance_norm",
          "batch_norm", "softmax", "sqrt", "rsqrt", "pow", "real_div"}
mlm = ct.convert(traced,
    inputs=[ct.TensorType(name="mix", shape=(1, 2, L)), ct.TensorType(name="spec", shape=(1, 4, FQ, T))],
    outputs=[ct.TensorType(name="specOut"), ct.TensorType(name="wave")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in KEEP32),
    convert_to="mlprogram")
mlm.short_description = ("HTDemucs v4 (Meta, MIT license) without STFT/iSTFT, 7.8 s segment at 44.1 kHz. "
    "Inputs normalized to mean 0 / std 1; outputs before de-normalization. Sources: drums, bass, other, vocals.")
mlm.author = "Converted for AppGuitarra from facebookresearch/demucs"
mlm.license = "MIT"
mlm.save("HTDemucs.mlpackage"); print("saved")
