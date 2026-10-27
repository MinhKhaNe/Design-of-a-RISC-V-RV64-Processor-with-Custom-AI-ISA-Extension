#!/usr/bin/env python3
"""Train a small CNN on the scikit-learn digits set (8x8, bundled offline), quantise it to INT8 with POWER-OF-TWO
scales (so the requantisation is exactly the Xai `qrelu`: (acc + 2^(s-1)) >> s, ReLU, clamp 0..127), run a bit-exact
integer reference inference, and export everything the C kernels need.

   python3 train_quant.py [--out ../src] [--bin .]

Network (HWC layout, channels fastest):
   input 8x8x1  -> conv3x3 1->8  (6x6x8) -> ReLU+requant -> conv3x3 8->16 (4x4x16) -> ReLU+requant
                -> maxpool2x2 (2x2x16 = 64 features) -> FC 64->10 (int32 logits, argmax)
Quantisation: input A0 = clamp(pixel*8, 0, 127) (scale 2^7); weights int8, one power-of-two scale per layer;
activations unsigned 0..127 with one power-of-two scale per layer, calibrated on the TRAINING set only.
To use PyTorch / MNIST instead: only `train_float()` has to be replaced by a function returning the same float arrays."""
import argparse, json, os, sys
import numpy as np
from sklearn.datasets import load_digits
from sklearn.model_selection import train_test_split

SEED = 2026
rng = np.random.default_rng(SEED)

# ------------------------------------------------------------------ float model (numpy, manual backprop)
def im2col(x, KH, KW):
    N, H, W, C = x.shape; OH, OW = H - KH + 1, W - KW + 1
    cols = np.empty((N, OH, OW, KH * KW * C), dtype=x.dtype)
    for ky in range(KH):
        for kx in range(KW):
            t = ky * KW + kx
            cols[..., t * C:(t + 1) * C] = x[:, ky:ky + OH, kx:kx + OW, :]
    return cols

def conv_fwd(x, W, b):                       # W: (KH, KW, C, OC)
    KH, KW, C, OC = W.shape
    cols = im2col(x, KH, KW)
    out = cols.reshape(-1, KH * KW * C) @ W.reshape(KH * KW * C, OC) + b
    return out.reshape(x.shape[0], cols.shape[1], cols.shape[2], OC), cols

def conv_bwd(dout, cols, W, xshape):
    KH, KW, C, OC = W.shape
    N, H, Wd, _ = xshape
    d2 = dout.reshape(-1, OC)
    dW = (cols.reshape(-1, KH * KW * C).T @ d2).reshape(W.shape)
    db = d2.sum(0)
    dcols = (d2 @ W.reshape(KH * KW * C, OC).T).reshape(cols.shape)
    dx = np.zeros(xshape)
    OH, OW = cols.shape[1], cols.shape[2]
    for ky in range(KH):
        for kx in range(KW):
            t = ky * KW + kx
            dx[:, ky:ky + OH, kx:kx + OW, :] += dcols[..., t * C:(t + 1) * C]
    return dx, dW, db

def pool_fwd(x):                              # (N,4,4,C) -> (N,2,2,C)
    N, H, W, C = x.shape
    r = x.reshape(N, H // 2, 2, W // 2, 2, C)
    out = r.max(axis=(2, 4))
    mask = (r == out[:, :, None, :, None, :])
    return out, mask

def pool_bwd(dout, mask):
    N, h, w, C = dout.shape
    m = mask / mask.sum(axis=(2, 4), keepdims=True)           # split ties evenly
    return (m * dout[:, :, None, :, None, :]).reshape(N, h * 2, w * 2, C)

def forward(p, x, keep=False):
    z1, c1 = conv_fwd(x, p["W1"], p["b1"]); a1 = np.maximum(z1, 0)
    z2, c2 = conv_fwd(a1, p["W2"], p["b2"]); a2 = np.maximum(z2, 0)
    pl, mask = pool_fwd(a2)
    f = pl.reshape(x.shape[0], -1)                            # (y, x, c) order
    logits = f @ p["Wf"] + p["bf"]
    return (logits, dict(z1=z1, a1=a1, z2=z2, a2=a2, c1=c1, c2=c2, mask=mask, f=f, x=x)) if keep else logits

def train_float(Xtr, ytr, epochs=120, bs=32, lr=2e-3):
    p = {"W1": rng.normal(0, np.sqrt(2 / 9), (3, 3, 1, 8)), "b1": np.zeros(8),
         "W2": rng.normal(0, np.sqrt(2 / 72), (3, 3, 8, 16)), "b2": np.zeros(16),
         "Wf": rng.normal(0, np.sqrt(2 / 64), (64, 10)), "bf": np.zeros(10)}
    m = {k: np.zeros_like(v) for k, v in p.items()}; v2 = {k: np.zeros_like(v) for k, v in p.items()}
    t = 0
    for ep in range(epochs):
        idx = rng.permutation(len(Xtr))
        for i in range(0, len(idx), bs):
            bi = idx[i:i + bs]; x, y = Xtr[bi], ytr[bi]
            logits, c = forward(p, x, keep=True)
            e = np.exp(logits - logits.max(1, keepdims=True)); pr = e / e.sum(1, keepdims=True)
            d = pr.copy(); d[np.arange(len(y)), y] -= 1; d /= len(y)
            g = {"Wf": c["f"].T @ d, "bf": d.sum(0)}
            df = (d @ p["Wf"].T).reshape(len(y), 2, 2, 16)
            da2 = pool_bwd(df, c["mask"]); dz2 = da2 * (c["z2"] > 0)
            da1, g["W2"], g["b2"] = conv_bwd(dz2, c["c2"], p["W2"], c["a1"].shape)
            dz1 = da1 * (c["z1"] > 0)
            _, g["W1"], g["b1"] = conv_bwd(dz1, c["c1"], p["W1"], x.shape)
            t += 1
            for k in p:
                gk = g[k] + 1e-4 * p[k] * (k[0] == "W")        # small weight decay
                m[k] = 0.9 * m[k] + 0.1 * gk; v2[k] = 0.999 * v2[k] + 0.001 * gk * gk
                p[k] -= lr * (m[k] / (1 - 0.9 ** t)) / (np.sqrt(v2[k] / (1 - 0.999 ** t)) + 1e-8)
        if ep % 30 == 29: print("  epoch %3d  train acc %.3f" % (ep + 1, (forward(p, Xtr).argmax(1) == ytr).mean()))
    return p

# ------------------------------------------------------------------ INT8 model (power-of-two scales) + exact integer reference
def pow2_weight_exp(W):                       # largest e with max|W| * 2^e <= 127
    return int(np.floor(np.log2(127.0 / np.abs(W).max())))

def quantise(p, calib_x, pct):
    q = {}
    e_in = 7                                                     # input scale 2^7 : A0 = pixel * 8
    _, c = forward(p, calib_x, keep=True)
    for name, act in (("1", c["a1"]), ("2", c["a2"])):
        W, b = p["W" + name], p["b" + name]
        e_w = pow2_weight_exp(W)
        amax = np.percentile(act[act > 0], pct) if pct < 100 else act.max()
        e_out = int(np.floor(np.log2(127.0 / amax)))
        e_out = min(e_out, e_in + e_w)                            # shift must be >= 0 (qrelu shifts right only)
        sh = e_in + e_w - e_out
        assert 0 <= sh <= 31, (name, sh)
        q["W" + name] = np.clip(np.round(W * 2.0 ** e_w), -127, 127).astype(np.int64)
        q["b" + name] = np.round(b * 2.0 ** (e_in + e_w)).astype(np.int64)
        q["sh" + name] = sh; q["ew" + name] = e_w; q["ea" + name] = e_out
        e_in = e_out
    e_wf = pow2_weight_exp(p["Wf"])
    q["Wf"] = np.clip(np.round(p["Wf"] * 2.0 ** e_wf), -127, 127).astype(np.int64)
    q["bf"] = np.round(p["bf"] * 2.0 ** (e_in + e_wf)).astype(np.int64); q["ewf"] = e_wf
    return q

def requant(acc, sh):                          # exactly the Xai qrelu: round-half-up, ReLU, saturate to 0..127
    rnd = (1 << (sh - 1)) if sh else 0
    return np.clip((acc + rnd) >> sh, 0, 127)

def int_infer(q, img_u8):
    """img_u8: (N,8,8) uint8 pixel*8 clamped. Returns int32 logits (N,10); asserts no int32 overflow."""
    x = img_u8.astype(np.int64)[..., None]
    for name in ("1", "2"):
        W = q["W" + name]; KH, KW, C, OC = W.shape
        acc = (im2col(x, KH, KW).reshape(-1, KH * KW * C) @ W.reshape(KH * KW * C, OC) + q["b" + name])
        acc = acc.reshape(x.shape[0], x.shape[1] - KH + 1, x.shape[2] - KW + 1, OC)
        assert np.abs(acc).max() < 2 ** 31
        x = requant(acc, q["sh" + name])
    pl = x.reshape(x.shape[0], 2, 2, 2, 2, 16).max(axis=(2, 4)).reshape(x.shape[0], -1)
    logits = pl @ q["Wf"] + q["bf"]
    assert np.abs(logits).max() < 2 ** 31
    return logits.astype(np.int32)

def to_u8(X):                                   # sklearn pixel 0..16 -> 0..127 (scale 2^7 / 16 = x8)
    return np.clip(np.round(X.reshape(-1, 8, 8) * 8), 0, 127).astype(np.uint8)

# ------------------------------------------------------------------ export
def c_arr(ctype, name, a, per_line=16, fmt="%d", align=True):
    flat = np.asarray(a).flatten().tolist()
    body = ",\n  ".join(", ".join(fmt % v for v in flat[i:i + per_line]) for i in range(0, len(flat), per_line))
    return "static const %s %s[%d]%s = {\n  %s\n};\n" % (ctype, name, len(flat), " __attribute__((aligned(8)))" if align else "", body)

def export(q, Xte_u8, yte, logits_te, out_dir, bin_dir, nimg=8):
    W1 = q["W1"]; W2 = q["W2"]; Wf = q["Wf"]
    w1 = np.ascontiguousarray(W1[:, :, 0, :].transpose(2, 0, 1))              # [oc][ky][kx]
    w1p = [[sum((int(w1[oc, ky, kx]) & 0xFF) << (8 * kx) for kx in range(3)) for ky in range(3)] for oc in range(8)]
    w2 = np.ascontiguousarray(W2.transpose(3, 0, 1, 2).reshape(16, 9, 8))      # [oc][tap][c]
    with open(os.path.join(out_dir, "nn_weights.h"), "w") as f:
        f.write("// GENERATED by nn/train_quant.py -- do not edit.  INT8 CNN, power-of-two scales (see the script header).\n#ifndef NN_WEIGHTS_H\n#define NN_WEIGHTS_H\n#include <stdint.h>\n\n")
        for n, v in (("NN_SH1", q["sh1"]), ("NN_SH2", q["sh2"]), ("NN_IMG", 8), ("NN_C1", 8), ("NN_C2", 16), ("NN_CLASSES", 10)):
            f.write("#define %-10s %d\n" % (n, v))
        f.write("\n// conv1: [oc][ky][kx] (scalar kernel) and the same rows zero-padded to 64 bit (Xai dot8 kernel)\n")
        f.write(c_arr("int8_t", "nn_w1", w1, 9) + c_arr("uint64_t", "nn_w1p", np.array(w1p, dtype=object), 3, "0x%016xULL") + c_arr("int32_t", "nn_b1", q["b1"], 8))
        f.write("// conv2: [oc][tap = ky*3+kx][c]  (8 channels = one 64-bit word per tap)\n")
        f.write(c_arr("int8_t", "nn_w2", w2, 8) + c_arr("int32_t", "nn_b2", q["b2"], 8))
        f.write("// fully connected: [class][feature], features in (y, x, c) order of the 2x2x16 pooled map\n")
        f.write(c_arr("int8_t", "nn_wf", Wf.T, 16) + c_arr("int32_t", "nn_bf", q["bf"], 10))
        f.write("\n#endif\n")
    with open(os.path.join(out_dir, "nn_data.h"), "w") as f:
        f.write("// GENERATED by nn/train_quant.py -- the first %d TEST images with the exact expected int32 logits.\n#ifndef NN_DATA_H\n#define NN_DATA_H\n#include <stdint.h>\n\n#define NN_NIMG %d\n" % (nimg, nimg))
        f.write(c_arr("uint8_t", "nn_img", Xte_u8[:nimg], 16) + c_arr("uint8_t", "nn_label", yte[:nimg], 16, align=False))
        f.write(c_arr("int32_t", "nn_expect", logits_te[:nimg], 10) + "\n#endif\n")
    Xte_u8.astype(np.uint8).tofile(os.path.join(bin_dir, "nn_test_images.bin"))
    yte.astype(np.uint8).tofile(os.path.join(bin_dir, "nn_test_labels.bin"))
    logits_te.astype("<i4").tofile(os.path.join(bin_dir, "nn_test_logits.bin"))

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out", default="../src"); ap.add_argument("--bin", default=".")
    a = ap.parse_args()
    X, y = load_digits(return_X_y=True)
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.3, random_state=0, stratify=y)
    xtr = (Xtr / 16.0).reshape(-1, 8, 8, 1); xte = (Xte / 16.0).reshape(-1, 8, 8, 1)
    print("train %d  test %d" % (len(xtr), len(xte)))
    p = train_float(xtr, ytr)
    acc_f = (forward(p, xte).argmax(1) == yte).mean()
    print("float32 test accuracy: %.4f" % acc_f)

    best = None
    f_tr = forward(p, xtr)
    for pct in (100, 99.99, 99.9, 99.5, 99):                       # calibrate on TRAINING data only
        q = quantise(p, xtr, pct)
        li = int_infer(q, to_u8(Xtr))
        acc_tr = (li.argmax(1) == ytr).mean()
        mse = float(np.mean((li * 2.0 ** -(q["ea2"] + q["ewf"]) - f_tr) ** 2))      # logit error in real units (tie-breaker)
        print("  calibration percentile %-6s -> shifts (%d, %d), INT8 train accuracy %.4f, logit MSE vs float %.5f" % (pct, q["sh1"], q["sh2"], acc_tr, mse))
        if best is None or (acc_tr, -mse) > (best[0], -best[1]): best = (acc_tr, mse, pct, q)
    _, _, pct, q = best
    xte_u8 = to_u8(Xte); lo = int_infer(q, xte_u8)
    acc_q = (lo.argmax(1) == yte).mean(); agree = (lo.argmax(1) == forward(p, xte).argmax(1)).mean()
    print("chosen percentile %s: INT8 test accuracy %.4f (float %.4f), same prediction as float on %.1f%% of test images" % (pct, acc_q, acc_f, 100 * agree))
    print("scales: input 2^7; conv1 w 2^%d out 2^%d shift %d; conv2 w 2^%d out 2^%d shift %d; fc w 2^%d" % (q["ew1"], q["ea1"], q["sh1"], q["ew2"], q["ea2"], q["sh2"], q["ewf"]))
    os.makedirs(a.out, exist_ok=True); os.makedirs(a.bin, exist_ok=True)
    export(q, xte_u8, yte, lo, a.out, a.bin)
    json.dump({"float_test_acc": float(acc_f), "int8_test_acc": float(acc_q), "agreement": float(agree), "percentile": pct,
               "shift1": q["sh1"], "shift2": q["sh2"], "n_test": int(len(yte)), "seed": SEED}, open(os.path.join(a.bin, "nn_report.json"), "w"), indent=1)
    print("exported nn_weights.h, nn_data.h to %s and nn_test_*.bin to %s" % (a.out, a.bin))

if __name__ == "__main__":
    main()
