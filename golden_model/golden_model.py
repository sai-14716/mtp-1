#!/usr/bin/env python3
"""
Bit-exact integer golden model: Conv1(3x3,1->2)+ReLU -> Conv2(2x2,2->2) -> GAP -> 2-class softmax-CE
Pure Python ints (no float in the datapath) so the Verilog must match EXACTLY.

Number formats
  data / weights / biases / activations : Q4.12 signed 16-bit  (real = int / 4096)
  accumulators                          : Q8.24 (wide int, we track the max width needed)
  requant: round-half-up (add 1<<11, arithmetic >>12) then saturate to [-32768, 32767]
  GAP    : logit = requant(sum(z2) * INV25)          INV25 = 164  (~4096/25)
  softmax: 2-class -> p1 = SIGMOID_LUT[(clip(l1-l0) >> 7) + 256]  (Q4.12, p0 = 4096 - p1)
  SGD    : w -= round(dW_acc >> (12 + LR_SHIFT));  b -= round(db >> LR_SHIFT)   (lr = 2^-LR_SHIFT)
"""
import math, os, csv
import numpy as np
from sklearn.datasets import load_digits

# ----------------------------------------------------------------- config
FRAC = 12
QMAX, QMIN = (1 << 15) - 1, -(1 << 15)
INV25 = 164
LR_SHIFT = 3            # lr = 1/8
EPOCHS = 5
N_PER_CLASS = 100       # 0 vs 1, 200 samples total, alternating, NO shuffling
LUT_N, LUT_SHIFT = 512, 7
OUT = os.path.dirname(os.path.abspath(__file__))

# ----------------------------------------------------------------- integer helpers
def sat(v):            return max(QMIN, min(QMAX, v))
def rshift_round(v, s): return v if s == 0 else (v + (1 << (s - 1))) >> s   # arithmetic shift on python ints
def requant(acc):      return sat(rshift_round(acc, FRAC))
def to_q(x):           return sat(int(math.floor(x * (1 << FRAC) + 0.5)))
def hex16(v):          return f"{v & 0xFFFF:04x}"

max_acc = 0
def track(a):
    global max_acc
    max_acc = max(max_acc, abs(a))
    return a

# ----------------------------------------------------------------- sigmoid LUT (shared with Verilog via hex)
SIG_LUT = [int(math.floor(4096.0 / (1.0 + math.exp(-((i - LUT_N // 2) + 0.5) / 32.0)) + 0.5))
           for i in range(LUT_N)]

# ----------------------------------------------------------------- data
def make_data():
    d = load_digits()
    i0 = np.where(d.target == 0)[0][:N_PER_CLASS]
    i1 = np.where(d.target == 1)[0][:N_PER_CLASS]
    idx = np.empty(2 * N_PER_CLASS, dtype=int)
    idx[0::2], idx[1::2] = i0, i1                       # 0,1,0,1,...
    pix = d.data[idx].astype(int)                       # 0..16
    imgs = (pix * 256).reshape(-1, 8, 8)                # 16*256 = 4096 = 1.0 exactly in Q4.12
    return imgs.tolist(), d.target[idx].tolist()

# ----------------------------------------------------------------- parameters
def init_params():
    rng = np.random.RandomState(0)
    q = lambda a: [[[to_q(v) for v in row] for row in m] for m in a]
    W1 = q(rng.randn(2, 3, 3) * 0.3)                                              # [o][u][v]
    w2 = rng.randn(2, 2, 2, 2) * 0.3                                              # [k][c][u][v]
    W2 = [[[[to_q(w2[k][c][u][v]) for v in range(2)] for u in range(2)] for c in range(2)] for k in range(2)]
    return dict(W1=W1, b1=[0, 0], W2=W2, b2=[0, 0])

def pack(P):
    """flat order: W1[o][u][v] (18) | b1 (2) | W2[k][c][u][v] (16) | b2 (2)  = 38 words"""
    f = []
    for o in range(2):
        for u in range(3):
            for v in range(3): f.append(P['W1'][o][u][v])
    f += P['b1']
    for k in range(2):
        for c in range(2):
            for u in range(2):
                for v in range(2): f.append(P['W2'][k][c][u][v])
    f += P['b2']
    return f

# ----------------------------------------------------------------- forward
def forward(P, x):
    W1, b1, W2, b2 = P['W1'], P['b1'], P['W2'], P['b2']
    z1 = [[[0] * 6 for _ in range(6)] for _ in range(2)]
    for o in range(2):
        for i in range(6):
            for j in range(6):
                acc = b1[o] << FRAC
                for u in range(3):
                    for v in range(3):
                        acc += x[i + u][j + v] * W1[o][u][v]
                z1[o][i][j] = requant(track(acc))
    a1 = [[[max(0, z1[o][i][j]) for j in range(6)] for i in range(6)] for o in range(2)]

    z2 = [[[0] * 5 for _ in range(5)] for _ in range(2)]
    for k in range(2):
        for i in range(5):
            for j in range(5):
                acc = b2[k] << FRAC
                for c in range(2):
                    for u in range(2):
                        for v in range(2):
                            acc += a1[c][i + u][j + v] * W2[k][c][u][v]
                z2[k][i][j] = requant(track(acc))

    s = [sum(z2[k][i][j] for i in range(5) for j in range(5)) for k in range(2)]   # GAP sum (wide)
    logit = [sat(rshift_round(track(s[k] * INV25), FRAC)) for k in range(2)]
    d = sat(logit[1] - logit[0])
    p1 = SIG_LUT[(d >> LUT_SHIFT) + LUT_N // 2]
    return dict(z1=z1, a1=a1, z2=z2, s=s, logit=logit, d=d, p=[4096 - p1, p1])

# ----------------------------------------------------------------- backward + update
def train_step(P, x, label):
    f = forward(P, x)
    a1, z1, p = f['a1'], f['z1'], f['p']
    dlog1 = p[1] - label * 4096
    dlog = [-dlog1, dlog1]                                   # softmax-CE, 2 classes
    dz2 = [rshift_round(dlog[k] * INV25, FRAC) for k in range(2)]   # GAP backward (same for all 25 pos)
    db2 = [25 * dz2[k] for k in range(2)]

    dW2 = [[[[0, 0], [0, 0]] for _ in range(2)] for _ in range(2)]
    for k in range(2):
        for c in range(2):
            for u in range(2):
                for v in range(2):
                    acc = 0
                    for i in range(5):
                        for j in range(5):
                            acc += dz2[k] * a1[c][i + u][j + v]
                    dW2[k][c][u][v] = track(acc)             # Q8.24

    da1 = [[[0] * 6 for _ in range(6)] for _ in range(2)]
    for c in range(2):
        for m in range(6):
            for n in range(6):
                acc = 0
                for k in range(2):
                    for u in range(2):
                        for v in range(2):
                            i, j = m - u, n - v
                            if 0 <= i < 5 and 0 <= j < 5:
                                acc += dz2[k] * P['W2'][k][c][u][v]
                da1[c][m][n] = requant(track(acc))
    dz1 = [[[da1[c][m][n] if z1[c][m][n] > 0 else 0 for n in range(6)] for m in range(6)] for c in range(2)]
    db1 = [sum(dz1[o][i][j] for i in range(6) for j in range(6)) for o in range(2)]

    dW1 = [[[0] * 3 for _ in range(3)] for _ in range(2)]
    for o in range(2):
        for u in range(3):
            for v in range(3):
                acc = 0
                for i in range(6):
                    for j in range(6):
                        acc += dz1[o][i][j] * x[i + u][j + v]
                dW1[o][u][v] = track(acc)

    # ---- SGD update (in place)
    sh = FRAC + LR_SHIFT
    for o in range(2):
        for u in range(3):
            for v in range(3):
                P['W1'][o][u][v] = sat(P['W1'][o][u][v] - rshift_round(dW1[o][u][v], sh))
        P['b1'][o] = sat(P['b1'][o] - rshift_round(db1[o], LR_SHIFT))
    for k in range(2):
        for c in range(2):
            for u in range(2):
                for v in range(2):
                    P['W2'][k][c][u][v] = sat(P['W2'][k][c][u][v] - rshift_round(dW2[k][c][u][v], sh))
        P['b2'][k] = sat(P['b2'][k] - rshift_round(db2[k], LR_SHIFT))

    f.update(dlog=dlog, dz2=dz2, db2=db2, dW2=dW2, da1=da1, dz1=dz1, db1=db1, dW1=dW1)
    return f

def loss_float(p, label):                      # monitoring only, NOT part of the hardware datapath
    pr = max(p[label], 1) / 4096.0
    return -math.log(pr)

def evaluate(P, imgs, labels):
    ok, L = 0, 0.0
    for x, y in zip(imgs, labels):
        f = forward(P, x)
        ok += int((f['logit'][1] > f['logit'][0]) == (y == 1))
        L += loss_float(f['p'], y)
    return ok / len(imgs), L / len(imgs)

# ----------------------------------------------------------------- export helpers
def write_lines(name, lines):
    with open(os.path.join(OUT, name), 'w') as fh:
        fh.write("\n".join(lines) + "\n")

def dump_tensor(fh, name, t):
    fh.write(f"{name} = {t}\n")

# ----------------------------------------------------------------- main
if __name__ == "__main__":
    imgs, labels = make_data()
    P = init_params()
    init_flat = pack(P)
    assert len(init_flat) == 38

    write_lines("data.hex",        [hex16(v) for im in imgs for row in im for v in row])   # 200*64 words
    write_lines("labels.hex",      [f"{l:01x}" for l in labels])
    write_lines("init_weights.hex", [hex16(v) for v in init_flat])
    write_lines("sigmoid_lut.hex", [f"{v:04x}" for v in SIG_LUT])

    acc0, loss0 = evaluate(P, imgs, labels)
    print(f"before training: acc={acc0*100:.1f}%  mean loss={loss0:.4f}")

    param_hex, rows = [], []
    step = 0
    for ep in range(EPOCHS):
        for n, (x, y) in enumerate(zip(imgs, labels)):
            if step == 0:                                    # full dump of the very first step
                Pbefore = pack(P)
                f = train_step(P, x, y)
                with open(os.path.join(OUT, "step0_dump.txt"), "w") as fh:
                    fh.write(f"sample={n} label={y}\n")
                    dump_tensor(fh, "x", x)
                    dump_tensor(fh, "params_before(38)", Pbefore)
                    for key in ["z1", "a1", "z2", "s", "logit", "d", "p", "dlog", "dz2", "db2",
                                "dW2", "da1", "dz1", "db1", "dW1"]:
                        dump_tensor(fh, key, f[key])
                    dump_tensor(fh, "params_after(38)", pack(P))
            else:
                f = train_step(P, x, y)
            flat = pack(P)
            param_hex += [hex16(v) for v in flat]
            rows.append([step, n, y, f['logit'][0], f['logit'][1], f['p'][1],
                         f"{loss_float(f['p'], y):.5f}"] + flat)
            step += 1
        a, l = evaluate(P, imgs, labels)
        print(f"epoch {ep+1}: acc={a*100:.1f}%  mean loss={l:.4f}")

    write_lines("params_log.hex", param_hex)                 # steps*38 words, step-major
    with open(os.path.join(OUT, "train_log.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["step", "sample", "label", "logit0", "logit1", "p1", "loss"] +
                   [f"W1_{i}" for i in range(18)] + ["b1_0", "b1_1"] +
                   [f"W2_{i}" for i in range(16)] + ["b2_0", "b2_1"])
        w.writerows(rows)

    print(f"steps={step}, max |accumulator| = {max_acc}  (needs {max_acc.bit_length()+1} signed bits)")
    print("final params:", pack(P))
