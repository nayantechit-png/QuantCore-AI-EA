"""
QuantCore LSTM Price Forecaster
================================
Predicts next-bar direction (UP / DOWN) and probability using a
2-layer LSTM trained on rolling windows of engineered features.

Features per bar
----------------
  close_ret     : 1-bar log return
  ema_ratio_20  : close / EMA(20) − 1
  ema_ratio_200 : close / EMA(200) − 1
  rsi_norm      : RSI(14) / 100
  atr_norm      : ATR(14) / close
  vol_norm      : volume z-score (0 if unavailable)

Architecture
------------
  Input  →  LSTM(64)  →  Dropout(0.2)
         →  LSTM(32)  →  Dropout(0.2)
         →  Linear(1) →  Sigmoid
  Output : probability of UP move on next bar

Training
--------
  Walk-forward: train on first 70%, validate on next 15%, test last 15%
  Loss   : BCELoss
  Optim  : Adam(lr=1e-3, weight_decay=1e-4)
  Early stop : patience = 10 epochs on val loss

Usage
-----
  from quantcore.strategies.lstm_forecaster import LSTMForecaster

  # Standalone training + prediction
  forecaster = LSTMForecaster(window=30, epochs=50)
  forecaster.train("EURUSD=X", period="2y")
  prob, direction = forecaster.predict_next("EURUSD=X")

  # CLI
  python lstm_forecaster.py --symbol EURUSD=X --period 2y
  python lstm_forecaster.py --symbol GC=F     --period 2y --epochs 100
"""

import argparse, sys, warnings
from pathlib import Path
from typing import Tuple

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

# ── Optional: progress bar ────────────────────────────────────────────
try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False

# ── PyTorch ───────────────────────────────────────────────────────────
try:
    import torch
    import torch.nn as nn
    from torch.utils.data import DataLoader, TensorDataset
    TORCH_OK = True
except ImportError:
    TORCH_OK = False

torch.manual_seed(42)
np.random.seed(42)

# ══════════════════════════════════════════════════════════════════════
#  DATA PIPELINE
# ══════════════════════════════════════════════════════════════════════

def fetch_features(symbol: str, period: str = "2y",
                   interval: str = "1h") -> pd.DataFrame:
    """Download OHLCV and engineer 12 input features including session timing."""
    import yfinance as yf

    df = yf.download(symbol, period=period, interval=interval,
                     progress=False, auto_adjust=True)
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df.columns = df.columns.str.lower()
    df = df.dropna()

    c  = df["close"]; h = df["high"]; l = df["low"]
    idx = pd.to_datetime(df.index).tz_localize(None)

    # ── Price features ────────────────────────────────────────────────
    log_ret  = np.log(c / c.shift(1)).fillna(0)
    log_ret2 = np.log(c / c.shift(2)).fillna(0)
    log_ret5 = np.log(c / c.shift(5)).fillna(0)

    # EMAs
    ema20  = c.ewm(span=20,  adjust=False).mean()
    ema50  = c.ewm(span=50,  adjust=False).mean()
    ema200 = c.ewm(span=200, adjust=False).mean()
    ema_r20  = (c / ema20  - 1).clip(-0.05, 0.05).fillna(0)
    ema_r200 = (c / ema200 - 1).clip(-0.10, 0.10).fillna(0)

    # RSI(14)
    d    = c.diff()
    gain = d.clip(lower=0).rolling(14).mean()
    loss = (-d.clip(upper=0)).rolling(14).mean()
    rsi  = (100 - 100/(1 + gain / loss.replace(0, np.nan))).fillna(50) / 100

    # Stochastic %K
    low14 = l.rolling(14).min(); high14 = h.rolling(14).max()
    stoch = ((c - low14) / (high14 - low14 + 1e-9)).fillna(0.5)

    # ATR(14) normalised
    tr   = pd.concat([h-l,(h-c.shift()).abs(),(l-c.shift()).abs()],axis=1).max(axis=1)
    atr  = tr.ewm(alpha=1/14, adjust=False).mean()
    atr_n= (atr / c).fillna(0).clip(0, 0.05)

    # Volume z-score
    vol  = df.get("volume", pd.Series(0, index=c.index)).fillna(0)
    vmean= vol.rolling(20).mean().replace(0,1)
    vstd = vol.rolling(20).std().replace(0,1).fillna(1)
    vol_z= ((vol - vmean)/vstd).fillna(0).clip(-3, 3)

    # ── Temporal / session features ───────────────────────────────────
    hour    = idx.hour / 23.0                           # 0..1
    dow     = idx.dayofweek / 6.0                       # Mon=0, Fri=1
    # Session binary flags (UTC)
    tokyo   = ((idx.hour >= 0)  & (idx.hour < 8) ).astype(float)
    london  = ((idx.hour >= 7)  & (idx.hour < 16)).astype(float)
    newyork = ((idx.hour >= 12) & (idx.hour < 21)).astype(float)

    # ── Target ────────────────────────────────────────────────────────
    target = (c.shift(-1) > c).astype(float)

    feat = pd.DataFrame({
        "ret1":    log_ret,
        "ret2":    log_ret2,
        "ret5":    log_ret5,
        "ema_r20": ema_r20,
        "ema_r200":ema_r200,
        "rsi":     rsi,
        "stoch":   stoch,
        "atr":     atr_n,
        "vol":     vol_z,
        "hour":    pd.Series(np.array(hour),   index=c.index),
        "dow":     pd.Series(np.array(dow),    index=c.index),
        "london":  pd.Series(np.array(london), index=c.index),
        "target":  target,
    }, index=c.index).dropna()

    return feat


def make_sequences(feat: pd.DataFrame, window: int = 30,
                   test_split: float = 0.15,
                   val_split:  float = 0.15) -> dict:
    """Slice features into (seq_len, n_features) windows."""
    X_cols = [c for c in feat.columns if c != "target"]
    X_raw  = feat[X_cols].values.astype(np.float32)
    y_raw  = feat["target"].values.astype(np.float32)

    # Normalize features (per-feature z-score on train set)
    n      = len(X_raw)
    n_test = int(n * test_split)
    n_val  = int(n * val_split)
    n_train= n - n_test - n_val

    mu  = X_raw[:n_train].mean(axis=0)
    std = X_raw[:n_train].std(axis=0) + 1e-8
    X   = (X_raw - mu) / std

    # Build windows
    Xs, ys = [], []
    for i in range(window, len(X)):
        Xs.append(X[i-window:i])
        ys.append(y_raw[i])
    Xs = np.array(Xs); ys = np.array(ys)

    # Offsets account for window warm-up
    train_end  = n_train - window
    val_end    = train_end + n_val

    return {
        "X_train": Xs[:train_end],   "y_train": ys[:train_end],
        "X_val":   Xs[train_end:val_end], "y_val": ys[train_end:val_end],
        "X_test":  Xs[val_end:],     "y_test": ys[val_end:],
        "mu": mu, "std": std,
        "n_features": len(X_cols),
        "window": window,
    }


# ══════════════════════════════════════════════════════════════════════
#  MODEL
# ══════════════════════════════════════════════════════════════════════

class _LSTMNet(nn.Module):
    def __init__(self, n_features: int, hidden1: int = 64,
                 hidden2: int = 32, dropout: float = 0.2):
        super().__init__()
        self.lstm1    = nn.LSTM(n_features, hidden1, batch_first=True)
        self.drop1    = nn.Dropout(dropout)
        self.lstm2    = nn.LSTM(hidden1, hidden2, batch_first=True)
        self.drop2    = nn.Dropout(dropout)
        self.fc       = nn.Linear(hidden2, 1)
        self.sigmoid  = nn.Sigmoid()

    def forward(self, x):
        out, _ = self.lstm1(x)
        out    = self.drop1(out)
        out, _ = self.lstm2(out)
        out    = self.drop2(out[:, -1, :])   # last time step
        return self.sigmoid(self.fc(out)).squeeze(-1)


# ══════════════════════════════════════════════════════════════════════
#  FORECASTER CLASS
# ══════════════════════════════════════════════════════════════════════

class LSTMForecaster:
    """
    Train and serve an LSTM directional forecaster.

    Parameters
    ----------
    window  : look-back window in bars (default 30)
    epochs  : max training epochs (default 60)
    patience: early stopping patience (default 10)
    batch   : batch size (default 64)
    lr      : learning rate (default 1e-3)
    """

    def __init__(self, window: int = 30, epochs: int = 60,
                 patience: int = 10, batch: int = 64, lr: float = 1e-3):
        if not TORCH_OK:
            raise ImportError("PyTorch required: pip install torch")
        self.window   = window
        self.epochs   = epochs
        self.patience = patience
        self.batch    = batch
        self.lr       = lr
        self.model: _LSTMNet | None = None
        self.meta:  dict            = {}
        self.symbol: str            = ""
        self.trained: bool          = False

    # ── train ─────────────────────────────────────────────────────────
    def train(self, symbol: str, period: str = "2y",
              interval: str = "1h", verbose: bool = True) -> dict:
        self.symbol = symbol
        if verbose:
            print(f"\n{'='*55}")
            print(f"  QuantCore LSTM — {symbol}  ({period} {interval})")
            print(f"{'='*55}")

        feat = fetch_features(symbol, period, interval)
        data = make_sequences(feat, self.window)

        self.meta = {"mu": data["mu"], "std": data["std"],
                     "window": self.window, "n_features": data["n_features"]}

        self.model = _LSTMNet(data["n_features"])
        optim   = torch.optim.Adam(self.model.parameters(),
                                   lr=self.lr, weight_decay=1e-4)
        loss_fn = nn.BCELoss()

        def _loader(X, y, shuffle=True):
            ds = TensorDataset(torch.FloatTensor(X), torch.FloatTensor(y))
            return DataLoader(ds, batch_size=self.batch, shuffle=shuffle)

        tr_loader = _loader(data["X_train"], data["y_train"])
        va_loader = _loader(data["X_val"],   data["y_val"],   shuffle=False)

        best_val  = float("inf")
        no_improv = 0
        history   = {"train_loss": [], "val_loss": [], "val_acc": []}

        epoch_iter = range(self.epochs)
        if verbose and HAS_TQDM:
            epoch_iter = tqdm(epoch_iter, desc="Training", unit="ep")

        for epoch in epoch_iter:
            # ── train step ────────────────────────────────────────────
            self.model.train()
            tr_loss = 0.0
            for xb, yb in tr_loader:
                optim.zero_grad()
                pred = self.model(xb)
                loss = loss_fn(pred, yb)
                loss.backward()
                nn.utils.clip_grad_norm_(self.model.parameters(), 1.0)
                optim.step()
                tr_loss += loss.item() * len(xb)
            tr_loss /= len(data["X_train"])

            # ── val step ──────────────────────────────────────────────
            self.model.eval()
            va_loss = 0.0; va_correct = 0
            with torch.no_grad():
                for xb, yb in va_loader:
                    pred = self.model(xb)
                    va_loss += loss_fn(pred, yb).item() * len(xb)
                    va_correct += ((pred > 0.5) == yb.bool()).sum().item()
            va_loss /= len(data["X_val"])
            va_acc   = va_correct / len(data["X_val"]) * 100

            history["train_loss"].append(round(tr_loss, 5))
            history["val_loss"].append(round(va_loss, 5))
            history["val_acc"].append(round(va_acc, 2))

            if verbose and not HAS_TQDM and (epoch+1) % 10 == 0:
                print(f"  Epoch {epoch+1:3d} | "
                      f"train {tr_loss:.4f} | val {va_loss:.4f} | "
                      f"val acc {va_acc:.1f}%")

            # ── early stopping ────────────────────────────────────────
            if va_loss < best_val - 1e-4:
                best_val  = va_loss
                no_improv = 0
                best_state = {k: v.clone() for k, v in self.model.state_dict().items()}
            else:
                no_improv += 1
                if no_improv >= self.patience:
                    if verbose: print(f"  ✋ Early stop at epoch {epoch+1}")
                    break

        self.model.load_state_dict(best_state)

        # ── test evaluation ───────────────────────────────────────────
        te_loader = _loader(data["X_test"], data["y_test"], shuffle=False)
        self.model.eval()
        preds, trues = [], []
        with torch.no_grad():
            for xb, yb in te_loader:
                p = self.model(xb)
                preds.extend(p.numpy()); trues.extend(yb.numpy())
        preds = np.array(preds); trues = np.array(trues)
        acc   = ((preds > 0.5) == trues).mean() * 100
        # Directional accuracy when model is confident (>60% prob)
        conf  = np.abs(preds - 0.5) > 0.10
        conf_acc = ((preds[conf] > 0.5) == trues[conf]).mean() * 100 if conf.sum() > 0 else 0
        conf_pct = conf.mean() * 100

        result = {
            "symbol":       symbol,
            "period":       period,
            "total_bars":   len(feat),
            "train_bars":   len(data["X_train"]),
            "test_bars":    len(data["X_test"]),
            "test_acc":     round(acc, 2),
            "confident_pct":round(conf_pct, 1),
            "confident_acc":round(conf_acc, 2),
            "best_val_loss":round(best_val, 5),
            "stopped_epoch":epoch + 1,
        }
        self.trained = True

        if verbose:
            print(f"\n  {'─'*48}")
            print(f"  Test accuracy        : {acc:.1f}%")
            print(f"  Confident calls      : {conf_pct:.1f}% of bars  →  acc {conf_acc:.1f}%")
            print(f"  Best val loss        : {best_val:.5f}")
            print(f"  Stopped at epoch     : {epoch+1}")
            print(f"  {'─'*48}")

        return result

    # ── predict ───────────────────────────────────────────────────────
    def predict(self, feat_window: np.ndarray) -> Tuple[float, str, str]:
        """
        Feed a (window, n_features) numpy array → (prob_up, direction, confidence).
        Returns prob_up ∈ [0,1], direction ∈ {BUY, SELL, NEUTRAL},
        confidence ∈ {HIGH, MEDIUM, LOW}.
        """
        if not self.trained or self.model is None:
            raise RuntimeError("Call .train() first")
        x = (feat_window - self.meta["mu"]) / self.meta["std"]
        t = torch.FloatTensor(x).unsqueeze(0)    # (1, window, features)
        self.model.eval()
        with torch.no_grad():
            prob = float(self.model(t).item())
        margin = abs(prob - 0.5)
        conf   = "HIGH" if margin > 0.15 else "MEDIUM" if margin > 0.08 else "LOW"
        dirn   = "BUY" if prob > 0.5 else "SELL"
        if margin < 0.03:
            dirn = "NEUTRAL"
        return round(prob, 4), dirn, conf

    def predict_next(self, symbol: str,
                     interval: str = "1h") -> Tuple[float, str, str]:
        """Fetch latest bars and predict the next bar direction."""
        if not self.trained:
            raise RuntimeError("Call .train() first")
        feat = fetch_features(symbol, period="3mo", interval=interval)
        X_cols = [c for c in feat.columns if c != "target"]
        window_data = feat[X_cols].values[-self.window:].astype(np.float32)
        if len(window_data) < self.window:
            raise ValueError(f"Need {self.window} bars, got {len(window_data)}")
        return self.predict(window_data)

    # ── save / load ───────────────────────────────────────────────────
    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        torch.save({"model_state": self.model.state_dict(),
                    "meta": self.meta, "config": {
                        "window":self.window,"n_features":self.meta["n_features"]}},
                   path)
        print(f"  ✅ Saved → {path}")

    def load(self, path: str) -> None:
        ck = torch.load(path, map_location="cpu")
        self.meta   = ck["meta"]
        self.window = ck["config"]["window"]
        self.model  = _LSTMNet(ck["config"]["n_features"])
        self.model.load_state_dict(ck["model_state"])
        self.model.eval()
        self.trained = True
        print(f"  ✅ Loaded ← {path}")


# ══════════════════════════════════════════════════════════════════════
#  MULTI-SYMBOL TRAINER
# ══════════════════════════════════════════════════════════════════════

def train_all(symbols: list, period: str = "2y", save_dir: str = "models") -> dict:
    """Train one LSTM per symbol and save. Returns summary dict."""
    results = {}
    for sym in symbols:
        print(f"\n{'#'*55}")
        print(f"  Training: {sym}")
        print(f"{'#'*55}")
        try:
            f = LSTMForecaster(window=30, epochs=60, patience=10)
            r = f.train(sym, period=period)
            path = f"{save_dir}/lstm_{sym.replace('=','_').replace('/','_')}.pt"
            f.save(path)
            results[sym] = {**r, "model_path": path, "status": "OK"}
        except Exception as e:
            results[sym] = {"status": "ERROR", "error": str(e)}
    return results


# ══════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore LSTM Forecaster")
    ap.add_argument("--symbol",   default="EURUSD=X", help="Yahoo Finance symbol")
    ap.add_argument("--period",   default="2y",        help="History period (1y/2y/3y)")
    ap.add_argument("--interval", default="1h",        help="Bar interval (1h/4h/1d)")
    ap.add_argument("--epochs",   type=int, default=60, help="Max epochs")
    ap.add_argument("--window",   type=int, default=30, help="Look-back window")
    ap.add_argument("--save",     default=None,         help="Save model to .pt file")
    ap.add_argument("--load",     default=None,         help="Load model from .pt file")
    ap.add_argument("--predict",  action="store_true",  help="Predict next bar after training")
    ap.add_argument("--all",      action="store_true",  help="Train all 4 CI symbols")
    args = ap.parse_args()

    if args.all:
        results = train_all(
            ["EURUSD=X", "GC=F", "GBPUSD=X", "USDJPY=X"],
            period=args.period,
            save_dir="models"
        )
        print("\n\n━━━ SUMMARY ━━━")
        for sym, r in results.items():
            if r["status"] == "OK":
                print(f"  {sym:12} | acc {r['test_acc']:.1f}% | "
                      f"conf acc {r['confident_acc']:.1f}% | {r['confident_pct']:.0f}% confident bars")
            else:
                print(f"  {sym:12} | ❌ {r['error']}")
        return

    f = LSTMForecaster(window=args.window, epochs=args.epochs)

    if args.load:
        f.load(args.load)
    else:
        f.train(args.symbol, args.period, args.interval)
        if args.save:
            f.save(args.save)

    if args.predict or not args.load:
        print(f"\n  Predicting next bar for {args.symbol}…")
        prob, direction, confidence = f.predict_next(args.symbol, args.interval)
        bar  = "█" * int(prob * 20)
        bar += "░" * (20 - len(bar))
        print(f"\n  ┌─────────────────────────────────┐")
        print(f"  │  Symbol    : {args.symbol:<20}│")
        print(f"  │  Direction : {direction:<20}│")
        print(f"  │  P(up)     : {prob:.4f} [{bar}]│")
        print(f"  │  Confidence: {confidence:<20}│")
        print(f"  └─────────────────────────────────┘\n")


if __name__ == "__main__":
    main()
