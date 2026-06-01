"""
train_mlp_offline.py
====================
Standalone offline trainer for BreakoutTrendAI.
Reads btai_log.csv produced by the EA, trains the same 32→24→12→1 MLP,
and writes btai_model.dat that the EA can hot-load.

No external AI framework required — pure numpy only.

Usage
-----
  python train_mlp_offline.py \
      --log  "C:/Users/.../MQL5/Files/btai_log.csv" \
      --out  "C:/Users/.../MQL5/Files/btai_model.dat" \
      --epochs 200 --lr 0.001

Architecture must match Config.mqh / AI_Filter.mqh exactly:
  NN_IN=32  NN_H1=24  NN_H2=12  NN_OUT=1
"""

import argparse
import csv
import math
import os
import sys
import numpy as np

# ── Architecture (must match EA constants) ────────────────────
NN_IN, NN_H1, NN_H2, NN_OUT = 32, 24, 12, 1


# ── Activations ──────────────────────────────────────────────
def relu(x):   return np.maximum(0.0, x)
def relu_d(x): return (x > 0.0).astype(float)
def sigmoid(x):
    x = np.clip(x, -20.0, 20.0)
    return 1.0 / (1.0 + np.exp(-x))


# ── Xavier init ──────────────────────────────────────────────
def xavier(rows, cols):
    return np.random.randn(rows, cols) * math.sqrt(2.0 / cols)


# ── Forward pass ─────────────────────────────────────────────
def forward(x, W1, b1, W2, b2, W3, b3):
    z1 = x @ W1.T + b1;  a1 = relu(z1)
    z2 = a1 @ W2.T + b2; a2 = relu(z2)
    z3 = a2 @ W3.T + b3; a3 = sigmoid(z3)
    return z1, a1, z2, a2, z3, a3


# ── Backward pass (BCE loss) ──────────────────────────────────
def backward(x, label, W1, b1, W2, b2, W3, b3,
             z1, a1, z2, a2, z3, a3, lr=0.001):
    n = x.shape[0]

    # Output
    dz3 = (a3 - label) / n                     # (n, 1)
    dW3 = (a2.T @ dz3).T                       # (1, H2)
    db3 = dz3.sum(axis=0)                      # (1,)

    # Layer 2
    da2 = dz3 @ W3                             # (n, H2)
    dz2 = da2 * relu_d(z2)                     # (n, H2)
    dW2 = (a1.T @ dz2).T                       # (H2, H1)
    db2 = dz2.sum(axis=0)                      # (H2,)

    # Layer 1
    da1 = dz2 @ W2                             # (n, H1)
    dz1 = da1 * relu_d(z1)                     # (n, H1)
    dW1 = (x.T @ dz1).T                        # (H1, IN)
    db1 = dz1.sum(axis=0)                      # (H1,)

    W3 -= lr * dW3;  b3 -= lr * db3
    W2 -= lr * dW2;  b2 -= lr * db2
    W1 -= lr * dW1;  b1 -= lr * db1

    return W1, b1, W2, b2, W3, b3


# ── CSV reader ────────────────────────────────────────────────
def load_log(csv_path):
    """
    Reads btai_log.csv.
    Returns list of dicts with keys: type, posId, direction,
    entry, sl, tp1, lots, score, profit, trainStep.
    """
    rows = []
    if not os.path.exists(csv_path):
        print(f"[WARN] log not found: {csv_path}")
        return rows
    with open(csv_path, newline='', encoding='utf-8-sig') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def build_dataset(rows):
    """
    Pairs each OPEN row with its matching CLOSE row by posId.
    Returns X (n, 32) proxy features and y (n, 1) labels.

    Because the full 32-dim vector is NOT stored in the log,
    we use the available logged fields as proxy features and
    zero-pad the rest. For production, log features explicitly.
    """
    opens = {r["posId"]: r for r in rows if r.get("type") == "OPEN"}
    closes = {r["posId"]: r for r in rows if r.get("type") == "CLOSE"}

    X, y = [], []
    for pid, cl in closes.items():
        if pid not in opens:
            continue
        op = opens[pid]
        try:
            direction = float(op.get("direction", 0) or 0)
            entry     = float(op.get("entry", 0) or 0)
            sl        = float(op.get("sl", 0) or 0)
            tp1       = float(op.get("tp1", 0) or 0)
            score     = float(op.get("score", 0) or 0)
            profit    = float(cl.get("profit", 0) or 0)
        except ValueError:
            continue

        sl_dist = abs(entry - sl) if abs(entry - sl) > 1e-10 else 1.0
        rr      = (tp1 - entry) / sl_dist if sl_dist else 0.0

        # Proxy feature vector (32-dim, zero-padded)
        feat = np.zeros(NN_IN)
        feat[0] = direction
        feat[1] = sl_dist
        feat[2] = rr
        feat[3] = score
        # feat[4..31] would be populated if full features were logged
        X.append(feat)

        # Soft label from profit sign
        label = 1.0 if profit > 0 else 0.0
        y.append([label])

    if not X:
        return np.empty((0, NN_IN)), np.empty((0, 1))
    return np.array(X, dtype=float), np.array(y, dtype=float)


# ── Standard scaler (fit + transform) ────────────────────────
def fit_scaler(X):
    mean = X.mean(axis=0)
    std  = X.std(axis=0)
    std[std < 1e-10] = 1.0
    return mean, std

def transform(X, mean, std):
    return np.clip((X - mean) / std, -3.0, 3.0)


# ── Weight file writer ────────────────────────────────────────
def save_model(path, W1, b1, W2, b2, W3, b3, mean, std, scaler_n=0, train_steps=0):
    """
    Writes btai_model.dat in the exact format AI_Filter.mqh reads:

        NN_IN NN_H1 NN_H2 NN_OUT
        [W1 flat row-major]
        [b1]
        [W2 flat row-major]
        [b2]
        [W3 flat row-major]       ← W3 shape (1,H2) → H2 values
        [b3]
        [scaler mean NN_IN values]
        [scaler M2  NN_IN values] ← we store var*N as M2 approximation
        [scaler_n]
        [train_steps]
    """
    def row(arr):
        return " ".join(f"{v:.8f}" for v in arr.ravel()) + "\n"

    M2 = (std ** 2) * max(scaler_n, 1)   # recover M2 from std

    with open(path, "w") as f:
        f.write(f"{NN_IN} {NN_H1} {NN_H2} {NN_OUT}\n")
        f.write(row(W1))
        f.write(row(b1))
        f.write(row(W2))
        f.write(row(b2))
        f.write(row(W3))
        f.write(row(b3))
        f.write(row(mean))
        f.write(row(M2))
        f.write(f"{scaler_n}\n")
        f.write(f"{train_steps}\n")

    print(f"[OK] model saved → {path}")


# ── Training loop ─────────────────────────────────────────────
def train(X, y, epochs=200, lr=0.001, batch=32):
    n = X.shape[0]
    if n == 0:
        print("[WARN] no paired trades found – random-initializing weights")

    W1 = xavier(NN_H1, NN_IN);  b1 = np.zeros(NN_H1)
    W2 = xavier(NN_H2, NN_H1);  b2 = np.zeros(NN_H2)
    W3 = xavier(NN_OUT, NN_H2); b3 = np.zeros(NN_OUT)

    if n == 0:
        return W1, b1, W2, b2, W3, b3

    for ep in range(1, epochs + 1):
        idx = np.random.permutation(n)
        ep_loss = 0.0
        for start in range(0, n, batch):
            xb = X[idx[start:start + batch]]
            yb = y[idx[start:start + batch]]
            z1, a1, z2, a2, z3, a3 = forward(xb, W1, b1, W2, b2, W3, b3)
            bce = -np.mean(yb * np.log(a3 + 1e-9) +
                           (1 - yb) * np.log(1 - a3 + 1e-9))
            ep_loss += bce
            W1, b1, W2, b2, W3, b3 = backward(
                xb, yb, W1, b1, W2, b2, W3, b3,
                z1, a1, z2, a2, z3, a3, lr)

        if ep % 20 == 0 or ep == epochs:
            _, _, _, _, _, a3_all = forward(X, W1, b1, W2, b2, W3, b3)
            acc = ((a3_all > 0.5) == (y > 0.5)).mean() * 100
            print(f"  epoch {ep:4d}  loss={ep_loss:.4f}  acc={acc:.1f}%")

    return W1, b1, W2, b2, W3, b3


# ── Entry point ───────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="BreakoutTrendAI offline trainer")
    parser.add_argument("--log",    default="btai_log.csv",   help="EA log CSV")
    parser.add_argument("--out",    default="btai_model.dat", help="output weights file")
    parser.add_argument("--epochs", type=int,   default=200)
    parser.add_argument("--lr",     type=float, default=0.001)
    parser.add_argument("--batch",  type=int,   default=32)
    args = parser.parse_args()

    print(f"Loading log: {args.log}")
    rows = load_log(args.log)
    print(f"  {len(rows)} rows loaded")

    X, y = build_dataset(rows)
    print(f"  {len(X)} paired trades found")

    if len(X) > 0:
        mean, std = fit_scaler(X)
        X = transform(X, mean, std)
    else:
        mean = np.zeros(NN_IN)
        std  = np.ones(NN_IN)

    print(f"Training {NN_IN}→{NN_H1}→{NN_H2}→{NN_OUT} MLP  "
          f"epochs={args.epochs} lr={args.lr}")
    W1, b1, W2, b2, W3, b3 = train(X, y, args.epochs, args.lr, args.batch)

    save_model(args.out, W1, b1, W2, b2, W3, b3,
               mean, std, scaler_n=len(X), train_steps=0)


if __name__ == "__main__":
    main()
