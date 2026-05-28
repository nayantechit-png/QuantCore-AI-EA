"""
QuantCore Genetic Algorithm — Signal Weight Optimizer
======================================================
Evolves the 5 signal weights (Trend, Momentum, Regime, Kalman, MTF)
plus key thresholds (min_score, sl_mult, tp_mult, risk_pct) using a
real-coded genetic algorithm with tournament selection, BLX-α crossover,
and Gaussian mutation.

Chromosome
----------
  [w_trend, w_momentum, w_regime, w_kalman, w_mtf,    ← weights (sum=1)
   min_score, sl_atr, tp_atr, risk_pct]               ← thresholds

Fitness
-------
  Composite score maximised:
    fitness = sharpe × (1 - abs(dd)/10) × profit_factor
  Penalised to 0 if prop-firm rule breached (DD ≥ 10%)

Algorithm
---------
  Population   : 30 individuals
  Generations  : 50
  Tournament   : size 3
  Crossover    : BLX-α (α=0.3), prob=0.8
  Mutation     : Gaussian σ=0.05, prob=0.15 per gene
  Elitism      : top 2 individuals carried forward

Usage
-----
  from quantcore.strategies.genetic_optimizer import GeneticOptimizer

  ga = GeneticOptimizer(pop_size=30, generations=50)
  best = ga.run("EURUSD=X", period="2y")
  print(best.params)   # → dict of optimised parameters

  # CLI
  python genetic_optimizer.py --symbol EURUSD=X --generations 50
  python genetic_optimizer.py --symbol GC=F     --generations 80 --pop 40
"""

import argparse, sys, warnings, time
from copy import deepcopy
from pathlib import Path
from typing import Optional

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(ROOT))

from backtest.run_backtest import fetch, build_features, run_backtest

np.random.seed(42)


# ══════════════════════════════════════════════════════════════════════
#  CHROMOSOME DEFINITION
# ══════════════════════════════════════════════════════════════════════

# Gene bounds: (min, max, name)
GENE_SPEC = [
    # Signal weights — will be normalised to sum=1 after crossover/mutation
    (0.05, 0.60, "w_trend"),
    (0.05, 0.60, "w_momentum"),
    (0.05, 0.60, "w_regime"),
    (0.05, 0.40, "w_kalman"),
    (0.05, 0.30, "w_mtf"),
    # Strategy thresholds
    (0.52, 0.75, "min_score"),
    (0.8,  2.5,  "sl_atr_mult"),
    (2.0,  5.0,  "tp_atr_mult"),
    (0.25, 1.50, "risk_pct"),
]

N_GENES  = len(GENE_SPEC)
N_WEIGHT = 5   # first 5 genes are weights

GENE_MINS = np.array([g[0] for g in GENE_SPEC])
GENE_MAXS = np.array([g[1] for g in GENE_SPEC])
GENE_NAMES= [g[2] for g in GENE_SPEC]


def _clip(genes: np.ndarray) -> np.ndarray:
    """Clip all genes to their valid range."""
    return np.clip(genes, GENE_MINS, GENE_MAXS)


def _normalise_weights(genes: np.ndarray) -> np.ndarray:
    """Ensure first 5 genes (weights) sum to 1."""
    g = genes.copy()
    total = g[:N_WEIGHT].sum()
    if total > 0:
        g[:N_WEIGHT] = g[:N_WEIGHT] / total
    return g


def genes_to_params(genes: np.ndarray, base_params: dict) -> dict:
    """Convert a chromosome to a full PARAMS dict for run_backtest."""
    p = dict(base_params)
    g = _normalise_weights(genes)
    p["w_trend"]     = float(g[0])
    p["w_momentum"]  = float(g[1])
    p["w_regime"]    = float(g[2])
    p["w_kalman"]    = float(g[3])
    p["w_mtf"]       = float(g[4])
    p["min_score"]   = float(g[5])
    p["sl_atr_mult"] = float(g[6])
    p["tp_atr_mult"] = float(g[7])
    p["risk_pct"]    = float(g[8])
    return p


def random_individual() -> np.ndarray:
    genes = np.random.uniform(GENE_MINS, GENE_MAXS)
    return _clip(_normalise_weights(genes))


# ══════════════════════════════════════════════════════════════════════
#  FITNESS FUNCTION
# ══════════════════════════════════════════════════════════════════════

_BASE_PARAMS = dict(
    ema_fast=20, ema_mid=50, ema_slow=200,
    rsi_period=14, adx_period=14, atr_period=14,
    trail_atr=0.8,
    max_daily_loss=4.5, max_total_loss=9.0, profit_lock_at=6.0,
    kf_delta=0.0001, kf_ve=0.001,
)


def fitness(genes: np.ndarray, df_feat: pd.DataFrame,
            symbol: str, balance: float = 10_000.0) -> float:
    """
    Evaluate one chromosome.  Returns composite score ∈ [0, ∞).
    Returns 0.0 if prop-firm check fails.
    """
    try:
        p   = genes_to_params(genes, _BASE_PARAMS)
        res = run_backtest(df_feat, p, start_balance=balance, symbol=symbol)

        if not res["prop_firm_pass"]:
            return 0.0

        sharpe = max(0.0, res["sharpe"])
        pf     = min(res["profit_factor"], 10.0)    # cap at 10
        dd     = max(res["max_drawdown_pct"], 0.01)
        wr     = res["win_rate_pct"] / 100.0

        # Composite: sharpe × (1 − dd/10) × sqrt(PF) × WR_bonus
        score  = sharpe * (1.0 - dd / 10.0) * np.sqrt(pf) * (0.5 + wr)
        return max(0.0, float(score))
    except Exception:
        return 0.0


# ══════════════════════════════════════════════════════════════════════
#  GENETIC OPERATORS
# ══════════════════════════════════════════════════════════════════════

def tournament_select(population: list, scores: np.ndarray,
                      k: int = 3) -> np.ndarray:
    idx = np.random.choice(len(population), k, replace=False)
    best = idx[np.argmax(scores[idx])]
    return population[best].copy()


def blx_alpha_crossover(p1: np.ndarray, p2: np.ndarray,
                        alpha: float = 0.3) -> tuple:
    """BLX-α crossover: generates offspring from [min-α×d, max+α×d]."""
    lo = np.minimum(p1, p2)
    hi = np.maximum(p1, p2)
    d  = hi - lo
    c1 = np.random.uniform(lo - alpha*d, hi + alpha*d)
    c2 = np.random.uniform(lo - alpha*d, hi + alpha*d)
    return (_clip(_normalise_weights(c1)),
            _clip(_normalise_weights(c2)))


def gaussian_mutate(genes: np.ndarray, sigma: float = 0.05,
                    prob: float = 0.15) -> np.ndarray:
    """Per-gene Gaussian mutation."""
    mask = np.random.random(N_GENES) < prob
    noise = np.random.normal(0, sigma, N_GENES) * (GENE_MAXS - GENE_MINS)
    g = genes + mask * noise
    return _clip(_normalise_weights(g))


# ══════════════════════════════════════════════════════════════════════
#  RESULT DATACLASS
# ══════════════════════════════════════════════════════════════════════

class GAResult:
    def __init__(self, genes: np.ndarray, score: float,
                 backtest: dict, generation: int):
        self.genes      = genes
        self.score      = score
        self.backtest   = backtest
        self.generation = generation
        self.params     = genes_to_params(genes, _BASE_PARAMS)

    def __repr__(self) -> str:
        g = _normalise_weights(self.genes)
        return (
            f"GAResult(score={self.score:.4f}  gen={self.generation})\n"
            f"  Weights  Trend:{g[0]:.3f}  Mom:{g[1]:.3f}  Reg:{g[2]:.3f}  "
            f"Kalman:{g[3]:.3f}  MTF:{g[4]:.3f}\n"
            f"  MinScore:{g[5]:.3f}  SL:{g[6]:.2f}×  TP:{g[7]:.2f}×  "
            f"Risk:{g[8]:.2f}%\n"
            f"  Backtest P&L:{self.backtest['net_pnl_pct']:+.1f}%  "
            f"DD:{self.backtest['max_drawdown_pct']:.1f}%  "
            f"Sharpe:{self.backtest['sharpe']:.2f}"
        )


# ══════════════════════════════════════════════════════════════════════
#  GENETIC OPTIMIZER
# ══════════════════════════════════════════════════════════════════════

class GeneticOptimizer:
    """
    Evolve QuantCore signal weights and strategy parameters.

    Parameters
    ----------
    pop_size    : population size (default 30)
    generations : number of generations (default 50)
    crossover_p : crossover probability (default 0.80)
    mutation_p  : per-gene mutation probability (default 0.15)
    elitism     : number of elites carried forward (default 2)
    """

    def __init__(self, pop_size: int = 30, generations: int = 50,
                 crossover_p: float = 0.80, mutation_p: float = 0.15,
                 elitism: int = 2):
        self.pop_size    = pop_size
        self.generations = generations
        self.crossover_p = crossover_p
        self.mutation_p  = mutation_p
        self.elitism     = elitism
        self.history: list[dict] = []

    def run(self, symbol: str, period: str = "2y",
            interval: str = "1h", balance: float = 10_000.0,
            verbose: bool = True) -> GAResult:

        t0 = time.time()
        if verbose:
            print(f"\n{'='*60}")
            print(f"  QuantCore Genetic Optimizer")
            print(f"  Symbol: {symbol}  |  Pop: {self.pop_size}  "
                  f"|  Gen: {self.generations}")
            print(f"{'='*60}")
            print("  Fetching data & building features…")

        df_h1 = fetch(symbol, period, interval)
        df_h4 = fetch(symbol, period, "4h")
        if len(df_h1) < 300:
            raise ValueError(f"Not enough data: {len(df_h1)} bars")
        if verbose:
            print(f"  Bars H1:{len(df_h1)}  H4:{len(df_h4)}\n")

        # Pre-build features once (expensive)
        from backtest.run_backtest import PARAMS as DEFAULT_PARAMS
        feat = build_features(df_h1, df_h4, DEFAULT_PARAMS)

        # ── Initialise population ─────────────────────────────────────
        population = [random_individual() for _ in range(self.pop_size)]
        scores     = np.array([fitness(ind, feat, symbol, balance)
                               for ind in population])
        best_ever  = GAResult(population[np.argmax(scores)],
                              float(np.max(scores)), {}, 0)

        for gen in range(self.generations):
            new_pop = []

            # Elitism
            elite_idx = np.argsort(scores)[-self.elitism:]
            for i in elite_idx:
                new_pop.append(population[i].copy())

            # Fill rest with crossover + mutation
            while len(new_pop) < self.pop_size:
                p1 = tournament_select(population, scores)
                p2 = tournament_select(population, scores)
                if np.random.random() < self.crossover_p:
                    c1, c2 = blx_alpha_crossover(p1, p2)
                else:
                    c1, c2 = p1.copy(), p2.copy()
                new_pop.append(gaussian_mutate(c1, prob=self.mutation_p))
                if len(new_pop) < self.pop_size:
                    new_pop.append(gaussian_mutate(c2, prob=self.mutation_p))

            population = new_pop[:self.pop_size]
            scores     = np.array([fitness(ind, feat, symbol, balance)
                                   for ind in population])

            best_idx   = int(np.argmax(scores))
            gen_best   = float(scores[best_idx])
            gen_mean   = float(np.mean(scores[scores > 0]))

            self.history.append({
                "gen": gen+1, "best": round(gen_best, 4),
                "mean": round(gen_mean, 4) if gen_mean > 0 else 0,
            })

            if gen_best > best_ever.score:
                p = genes_to_params(population[best_idx], _BASE_PARAMS)
                bt = run_backtest(feat, p, balance, symbol)
                best_ever = GAResult(population[best_idx].copy(),
                                     gen_best, bt, gen+1)

            if verbose and (gen+1) % 5 == 0:
                g = _normalise_weights(population[best_idx])
                print(f"  Gen {gen+1:3d}/{self.generations}  "
                      f"best:{gen_best:.4f}  mean:{gen_mean:.3f}  "
                      f"  T:{g[0]:.2f} M:{g[1]:.2f} R:{g[2]:.2f} "
                      f"K:{g[3]:.2f} MTF:{g[4]:.2f}  "
                      f"score:{g[5]:.2f}  TP:{g[7]:.1f}x  "
                      f"risk:{g[8]:.2f}%")

        elapsed = time.time() - t0
        if verbose:
            print(f"\n  ⏱  {elapsed:.1f}s\n")
            print("  ━━━  BEST INDIVIDUAL  ━━━")
            print(f"  {best_ever}")
            print(f"\n  Copy to QuantCore_AI_EA.set:")
            self._print_set_snippet(best_ever)

        return best_ever

    @staticmethod
    def _print_set_snippet(result: GAResult) -> None:
        g = _normalise_weights(result.genes)
        print(f"\n  W_Trend={g[0]:.4f}")
        print(f"  W_Momentum={g[1]:.4f}")
        print(f"  W_Regime={g[2]:.4f}")
        print(f"  W_Kalman={g[3]:.4f}")
        print(f"  W_MTF={g[4]:.4f}")
        print(f"  Inp_MinScore={g[5]:.3f}")
        print(f"  Inp_SL_ATR_Mult={g[6]:.2f}")
        print(f"  Inp_TP_ATR_Mult={g[7]:.2f}")
        print(f"  Inp_RiskPerTrade={g[8]:.2f}")


# ══════════════════════════════════════════════════════════════════════
#  CLI
# ══════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(description="QuantCore Genetic Optimizer")
    ap.add_argument("--symbol",      default="EURUSD=X")
    ap.add_argument("--period",      default="2y")
    ap.add_argument("--generations", type=int, default=50)
    ap.add_argument("--pop",         type=int, default=30)
    ap.add_argument("--balance",     type=float, default=10000.0)
    args = ap.parse_args()

    ga   = GeneticOptimizer(pop_size=args.pop, generations=args.generations)
    best = ga.run(args.symbol, args.period, balance=args.balance)

    # Summary
    print(f"\n{'='*60}")
    print(f"  FINAL OPTIMISED PARAMETERS")
    print(f"{'='*60}")
    for k, v in best.params.items():
        if k.startswith("w_"):
            print(f"  {k:20s}: {v:.4f}")
    print()
    for k, v in best.params.items():
        if not k.startswith("w_"):
            print(f"  {k:20s}: {v}")
    print(f"\n  Fitness score : {best.score:.4f}")
    print(f"  Net P&L       : {best.backtest.get('net_pnl_pct',0):+.1f}%")
    print(f"  Drawdown      : {best.backtest.get('max_drawdown_pct',0):.1f}%")
    print(f"  Sharpe        : {best.backtest.get('sharpe',0):.3f}")


if __name__ == "__main__":
    main()
