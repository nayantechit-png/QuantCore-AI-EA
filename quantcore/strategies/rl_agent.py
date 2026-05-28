"""
QuantCore RL Trading Agent — PPO / A2C
=======================================
A Gymnasium-compatible trading environment + Stable-Baselines3 PPO agent
that learns position sizing and entry/exit on forex/gold H1 data.

Environment
-----------
  State  (obs_window × n_features) flattened:
    close_ret, ema_r20, ema_r200, rsi, stoch, atr, vol_norm,
    position (-1=short, 0=flat, 1=long), unrealised_pnl_norm, hold_time_norm

  Actions (Discrete 3):
    0 = HOLD / no change
    1 = LONG  (open long or close short → go long)
    2 = SHORT (open short or close long → go short)

  Reward:
    Realised P&L on close + Sharpe-like running penalty for holding losers
    Prop-firm penalty: -10 if daily DD exceeds max_daily_loss

  Episode:
    Random start in training window, runs for episode_length bars

Architecture (PPO)
------------------
  Policy : MlpPolicy  [64, 64]
  LR     : 3e-4  (linear decay)
  Gamma  : 0.99
  n_steps: 2048
  Total  : 200k–500k steps

Usage
-----
  from quantcore.strategies.rl_agent import RLAgent

  agent = RLAgent()
  agent.train("EURUSD=X", period="2y", total_steps=300_000)
  action, info = agent.predict("EURUSD=X")

  # CLI
  python rl_agent.py --symbol EURUSD=X --steps 300000
  python rl_agent.py --symbol GC=F     --steps 500000 --algo A2C
"""

import argparse, warnings, sys
from pathlib import Path
from typing import Optional, Tuple

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

try:
    import gymnasium as gym
    from gymnasium import spaces
    GYM_OK = True
except ImportError:
    GYM_OK = False

try:
    from stable_baselines3 import PPO, A2C
    from stable_baselines3.common.env_checker import check_env
    from stable_baselines3.common.callbacks import EvalCallback, StopTrainingOnNoModelImprovement
    SB3_OK = True
except ImportError:
    SB3_OK = False


# ══════════════════════════════════════════════════════════════════════
#  FEATURE BUILDER  (reuse LSTM features)
# ══════════════════════════════════════════════════════════════════════

def _build_features(symbol: str, period: str = "2y", interval: str = "1h") -> pd.DataFrame:
    import yfinance as yf
    df = yf.download(symbol, period=period, interval=interval,
                     progress=False, auto_adjust=True)
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    df.columns = df.columns.str.lower()
    df = df.dropna()
    c = df["close"]; h = df["high"]; l = df["low"]

    log_ret  = np.log(c / c.shift(1)).fillna(0)
    ema20    = c.ewm(span=20,  adjust=False).mean()
    ema200   = c.ewm(span=200, adjust=False).mean()
    ema_r20  = (c / ema20  - 1).clip(-0.05, 0.05).fillna(0)
    ema_r200 = (c / ema200 - 1).clip(-0.10, 0.10).fillna(0)
    d    = c.diff()
    gain = d.clip(lower=0).rolling(14).mean()
    loss = (-d.clip(upper=0)).rolling(14).mean()
    rsi  = (100 - 100/(1 + gain/loss.replace(0, np.nan))).fillna(50) / 100
    low14 = l.rolling(14).min(); high14 = h.rolling(14).max()
    stoch = ((c - low14)/(high14 - low14 + 1e-9)).fillna(0.5)
    tr    = pd.concat([h-l,(h-c.shift()).abs(),(l-c.shift()).abs()],axis=1).max(axis=1)
    atr   = tr.ewm(alpha=1/14, adjust=False).mean()
    atr_n = (atr / c).clip(0, 0.05).fillna(0)
    vol   = df.get("volume", pd.Series(0, index=c.index)).fillna(0)
    vmean = vol.rolling(20).mean().replace(0, 1)
    vstd  = vol.rolling(20).std().replace(0, 1).fillna(1)
    vol_z = ((vol - vmean)/vstd).fillna(0).clip(-3, 3)

    feat = pd.DataFrame({
        "close": c, "atr_abs": atr,
        "ret":   log_ret,    "ema_r20":  ema_r20,
        "ema_r200": ema_r200,"rsi":      rsi,
        "stoch": stoch,      "atr":      atr_n,
        "vol":   vol_z,
    }).dropna()
    return feat


# ══════════════════════════════════════════════════════════════════════
#  GYMNASIUM TRADING ENVIRONMENT
# ══════════════════════════════════════════════════════════════════════

class ForexTradingEnv(gym.Env):
    """
    Single-instrument trading environment with prop-firm guardrails.

    Observation : float32 array of shape (obs_window * n_price_features + 3,)
                  Last 3 elements: position, unrealised_pnl_norm, hold_time_norm
    Action      : Discrete(3)  — 0=HOLD, 1=LONG, 2=SHORT
    """

    metadata = {"render_modes": ["human"]}

    N_PRICE_FEAT = 7  # ret, ema_r20, ema_r200, rsi, stoch, atr, vol

    def __init__(self,
                 feat: pd.DataFrame,
                 obs_window:     int   = 20,
                 episode_length: int   = 500,
                 initial_balance:float = 10_000.0,
                 risk_pct:       float = 1.0,      # % risk per trade
                 max_daily_loss: float = 4.5,
                 contract_size:  float = 100_000.0,
                 spread_cost:    float = 0.00002,  # EUR/USD typical spread
                 ):
        super().__init__()
        self.feat           = feat
        self.obs_window     = obs_window
        self.episode_length = episode_length
        self.initial_balance= initial_balance
        self.risk_pct       = risk_pct
        self.max_daily_loss = max_daily_loss
        self.contract_size  = contract_size
        self.spread_cost    = spread_cost

        n_obs = obs_window * self.N_PRICE_FEAT + 3
        self.observation_space = spaces.Box(
            low=-5.0, high=5.0, shape=(n_obs,), dtype=np.float32)
        self.action_space = spaces.Discrete(3)

        # Normalisation stats (computed on full dataset)
        price_cols = ["ret","ema_r20","ema_r200","rsi","stoch","atr","vol"]
        X = feat[price_cols].values
        self._mu  = X.mean(axis=0).astype(np.float32)
        self._std = (X.std(axis=0) + 1e-8).astype(np.float32)

        self._reset_internals()

    # ── reset ─────────────────────────────────────────────────────────
    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        max_start = len(self.feat) - self.episode_length - self.obs_window - 1
        self._start = self.np_random.integers(self.obs_window, max(self.obs_window+1, max_start))
        self._t     = self._start
        self._reset_internals()
        return self._obs(), {}

    def _reset_internals(self):
        self._balance     = self.initial_balance
        self._position    = 0      # -1=short, 0=flat, 1=long
        self._entry_price = 0.0
        self._entry_time  = 0
        self._lot         = 0.0
        self._day_start_bal = self.initial_balance
        self._last_day    = None
        self._total_pnl   = 0.0
        self._t           = self.obs_window

    # ── observation ───────────────────────────────────────────────────
    def _obs(self) -> np.ndarray:
        price_cols = ["ret","ema_r20","ema_r200","rsi","stoch","atr","vol"]
        window = self.feat[price_cols].values[self._t - self.obs_window:self._t]
        norm   = ((window - self._mu) / self._std).clip(-5, 5).astype(np.float32)
        flat   = norm.flatten()

        unrealised = 0.0
        if self._position != 0:
            price = float(self.feat["close"].iloc[self._t])
            move  = (price - self._entry_price) * self._position
            unrealised = move * self._lot * self.contract_size / self._balance
        hold_time = min((self._t - self._entry_time) / 100.0, 1.0) if self._position != 0 else 0.0

        extras = np.array([self._position / 1.0,
                           np.clip(unrealised, -1, 1),
                           hold_time], dtype=np.float32)
        return np.concatenate([flat, extras])

    # ── step ──────────────────────────────────────────────────────────
    def step(self, action: int):
        feat_row = self.feat.iloc[self._t]
        price    = float(feat_row["close"])
        atr_abs  = float(feat_row["atr_abs"])

        reward = 0.0

        # ── Close existing position ───────────────────────────────────
        if self._position != 0:
            move   = (price - self._entry_price) * self._position
            pnl    = move * self._lot * self.contract_size
            pnl   -= self.spread_cost * self._lot * self.contract_size  # spread
            closed = False
            if (action == 1 and self._position == -1) or \
               (action == 2 and self._position ==  1):
                closed = True
            if closed:
                self._balance   += pnl
                self._total_pnl += pnl
                reward          += pnl / self.initial_balance * 100   # normalised
                self._position   = 0

        # ── Open new position ─────────────────────────────────────────
        if action != 0 and self._position == 0:
            new_side = 1 if action == 1 else -1
            sl_dist   = atr_abs * 1.5
            risk_usd  = self._balance * self.risk_pct / 100
            self._lot = max(0.01, round(risk_usd / (sl_dist * self.contract_size), 2))
            self._lot       = min(self._lot, 50.0)
            self._entry_price = price
            self._entry_time  = self._t
            self._position    = new_side

        # ── Running reward for open position ──────────────────────────
        if self._position != 0:
            move  = (price - self._entry_price) * self._position
            upnl  = move * self._lot * self.contract_size
            reward += (upnl / self.initial_balance) * 0.01  # small step reward

        # ── Prop firm daily loss guard ────────────────────────────────
        day = self.feat.index[self._t].date() if hasattr(self.feat.index[self._t], "date") else None
        if day and day != self._last_day:
            self._day_start_bal = self._balance
            self._last_day = day
        equity = self._balance + (
            (price - self._entry_price) * self._position * self._lot * self.contract_size
            if self._position != 0 else 0.0)
        dd_day = (self._day_start_bal - equity) / self._day_start_bal * 100
        if dd_day >= self.max_daily_loss:
            reward -= 5.0   # heavy penalty for hitting daily limit

        self._t += 1
        done     = (self._t >= self._start + self.episode_length or
                    self._t >= len(self.feat) - 1)
        truncated= False

        info = {"balance": self._balance, "position": self._position,
                "total_pnl": self._total_pnl, "equity": equity}
        return self._obs(), float(reward), done, truncated, info

    def render(self):
        print(f"  t={self._t} | bal=${self._balance:,.2f} | pos={self._position} | pnl=${self._total_pnl:+,.2f}")


# ══════════════════════════════════════════════════════════════════════
#  RL AGENT WRAPPER
# ══════════════════════════════════════════════════════════════════════

class RLAgent:
    """
    Train and deploy a PPO or A2C trading agent.

    Parameters
    ----------
    algo         : 'PPO' or 'A2C'
    obs_window   : observation look-back (default 20)
    total_steps  : training timesteps (default 300k)
    """

    ALGOS = {"PPO": PPO, "A2C": A2C}

    def __init__(self, algo: str = "PPO", obs_window: int = 20,
                 total_steps: int = 300_000):
        if not (GYM_OK and SB3_OK):
            raise ImportError("Install: pip install gymnasium stable-baselines3")
        self.algo_name   = algo.upper()
        self.obs_window  = obs_window
        self.total_steps = total_steps
        self.model       = None
        self.feat        = None
        self.symbol      = ""
        self.trained     = False

    def train(self, symbol: str, period: str = "2y",
              interval: str = "1h", verbose: bool = True) -> dict:
        self.symbol = symbol
        if verbose:
            print(f"\n{'='*55}")
            print(f"  QuantCore RL Agent ({self.algo_name}) — {symbol}")
            print(f"{'='*55}")
            print(f"  Fetching {period} {interval} data…")

        self.feat = _build_features(symbol, period, interval)
        if verbose:
            print(f"  Bars: {len(self.feat)}")

        # 80% train, 20% test
        split  = int(len(self.feat) * 0.80)
        feat_tr = self.feat.iloc[:split]
        feat_te = self.feat.iloc[split:]

        env_tr = ForexTradingEnv(feat_tr, obs_window=self.obs_window)
        env_te = ForexTradingEnv(feat_te, obs_window=self.obs_window,
                                 episode_length=len(feat_te)-self.obs_window-2)

        AlgoCls = self.ALGOS[self.algo_name]
        self.model = AlgoCls(
            "MlpPolicy", env_tr,
            learning_rate=3e-4,
            gamma=0.99,
            n_steps=2048 if self.algo_name == "PPO" else 5,
            batch_size=64 if self.algo_name == "PPO" else None,
            policy_kwargs={"net_arch": [64, 64]},
            verbose=0,
        )

        if verbose: print(f"  Training {self.total_steps:,} steps…")
        self.model.learn(total_timesteps=self.total_steps)

        # ── evaluate on test env ──────────────────────────────────────
        obs, _ = env_te.reset()
        total_pnl = 0.0; n_ep = 0; rewards = []
        done = False; truncated = False
        while not (done or truncated):
            act, _ = self.model.predict(obs, deterministic=True)
            obs, rew, done, truncated, info = env_te.step(int(act))
            rewards.append(rew)
        total_pnl = info.get("total_pnl", 0)
        final_bal = info.get("balance", env_te.initial_balance)
        ret_pct   = (final_bal - env_te.initial_balance) / env_te.initial_balance * 100
        sharpe    = (np.mean(rewards) / (np.std(rewards) + 1e-9) *
                     np.sqrt(252 * (len(feat_te) / max(len(rewards),1))))

        result = {
            "symbol":       symbol, "algo": self.algo_name,
            "train_bars":   split,  "test_bars": len(feat_te),
            "final_balance":round(final_bal, 2),
            "return_pct":   round(ret_pct, 2),
            "total_pnl":    round(total_pnl, 2),
            "sharpe":       round(float(sharpe), 3),
            "total_steps":  self.total_steps,
        }
        self.trained = True

        if verbose:
            print(f"\n  {'─'*48}")
            print(f"  Test return     : {ret_pct:+.2f}%")
            print(f"  Total P&L       : ${total_pnl:+,.2f}")
            print(f"  Final balance   : ${final_bal:,.2f}")
            print(f"  Sharpe (approx) : {sharpe:.3f}")
            print(f"  {'─'*48}")

        return result

    def predict(self, symbol: str, interval: str = "1h") -> Tuple[str, dict]:
        """Predict action for the current market state."""
        if not self.trained:
            raise RuntimeError("Call .train() first")
        feat = _build_features(symbol, period="3mo", interval=interval)
        env  = ForexTradingEnv(feat, obs_window=self.obs_window,
                               episode_length=len(feat)-self.obs_window-2)
        # Run to last bar
        obs, _ = env.reset()
        env._t = len(feat) - self.obs_window - 1
        obs    = env._obs()
        act, _ = self.model.predict(obs, deterministic=True)
        actions = {0: "HOLD", 1: "LONG", 2: "SHORT"}
        return actions[int(act)], {"action_id": int(act)}

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.model.save(path)
        print(f"  ✅ Saved → {path}")

    def load(self, path: str, symbol: str = "") -> None:
        AlgoCls = self.ALGOS[self.algo_name]
        self.model = AlgoCls.load(path)
        self.symbol = symbol
        self.trained = True
        print(f"  ✅ Loaded ← {path}")


# ══════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore RL Agent")
    ap.add_argument("--symbol",   default="EURUSD=X")
    ap.add_argument("--period",   default="2y")
    ap.add_argument("--interval", default="1h")
    ap.add_argument("--steps",    type=int, default=300_000)
    ap.add_argument("--algo",     default="PPO", choices=["PPO","A2C"])
    ap.add_argument("--save",     default=None)
    ap.add_argument("--predict",  action="store_true")
    args = ap.parse_args()

    agent = RLAgent(algo=args.algo, total_steps=args.steps)
    agent.train(args.symbol, args.period, args.interval)

    if args.save:
        agent.save(args.save)

    if args.predict:
        action, info = agent.predict(args.symbol, args.interval)
        icons = {"HOLD":"⚪","LONG":"🟢","SHORT":"🔴"}
        print(f"\n  {icons.get(action,'❓')} RL Agent recommends: {action}\n")


if __name__ == "__main__":
    main()
