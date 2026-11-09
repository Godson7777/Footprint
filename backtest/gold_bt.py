"""XAUUSD (MT5 export, broker server time) pattern backtest with fixed reward:risk.

Patterns (long and short mirrors):
  BEAR_FLAG (short) / BULL_FLAG (long)       pole >= P x ATR in 10 bars, 5-15 bar pause < 50% of pole
  DOUBLE_BOTTOM (long) / DOUBLE_TOP (short)  two pivots <= 0.5 ATR apart, >= 10 bars apart, neckline >= 2 ATR
Entry: first close beyond the boundary (+0.1 ATR), filled at the next bar's open.
Stop:  2 x ATR(14) (default) or structural.
Exit:  fixed take profit at 2.5R or 3R (or the 3R-lagging trailing stop for reference).
       If stop and target are both inside one candle, the stop is assumed first (conservative).
Costs: the bar's own spread (MT5 <SPREAD> in points) on every trade + 0.05 USD slippage on stop exits.
       Swap is not modelled.

Usage: python backtest/gold_bt.py --csv path/to/XAUUSD_H1.csv
"""
import argparse
import math
import os

import numpy as np
import pandas as pd

from patterns_bt import pivots, K

POINT = 0.01
STOP_SLIP = 0.05
WINDOW, BUF = 100, 0.1


# ------------------------------------------------------------------ data
def load(path, rule=None):
    df = pd.read_csv(path, sep="\t")
    df.columns = [c.strip("<>").lower() for c in df.columns]
    df["t"] = pd.to_datetime(df["date"] + " " + df["time"], format="%Y.%m.%d %H:%M:%S")
    df = df.set_index("t")[["open", "high", "low", "close", "tickvol", "spread"]]
    df.columns = ["o", "h", "l", "c", "v", "spread"]
    df = df.iloc[:-1]                                   # last candle is still forming
    if rule:
        df = df.resample(rule, label="left", closed="left").agg(
            {"o": "first", "h": "max", "l": "min", "c": "last", "v": "sum", "spread": "median"}).dropna()
    return df


def context(df):
    h, l, c = df.h, df.l, df.c
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    ph, pl = pivots(h.values, l.values)
    return {"o": df.o.values, "h": h.values, "l": l.values, "c": c.values, "t": df.index,
            "atr": tr.rolling(14).mean().values, "sma": c.rolling(200).mean().values,
            "volr": (df.v / df.v.shift(1).rolling(20).mean()).values,
            "spread": df.spread.values * POINT, "ph": ph, "pl": pl}


# ------------------------------------------------------------------ detectors
def detect_flag(x, side, pole_min=3.0, pause_max=15, retrace=0.5):
    """side -1 = bear flag (break down), +1 = bull flag (mirror, break up)."""
    h, l, c, A = x["h"], x["l"], x["c"], x["atr"]
    n = len(c)
    H, L, C = pd.Series(h), pd.Series(l), pd.Series(c)
    hit = np.zeros(n, bool)
    struct = np.full(n, np.nan)
    for m in (5, 8, 12, 15):
        if m > pause_max:
            break
        pole = side * (C.shift(m + 1).values - C.shift(m + 11).values)     # size of the move in the flag's direction
        top = H.rolling(m).max().shift(1).values
        bot = L.rolling(m).min().shift(1).values
        cs = C.shift(m).values
        c1 = C.shift(1).values
        with np.errstate(invalid="ignore"):
            if side == -1:
                prior = L.rolling(11).min().shift(m + 1).values
                thr = bot - BUF * A
                ok = (bot >= prior - 0.25 * A) & (c1 >= cs) & (c < thr) & (c1 >= thr)
                stop = top + 0.25 * A
            else:
                prior = H.rolling(11).max().shift(m + 1).values
                thr = top + BUF * A
                ok = (top <= prior + 0.25 * A) & (c1 <= cs) & (c > thr) & (c1 <= thr)
                stop = bot - 0.25 * A
            ok &= np.isfinite(A) & (A > 0) & (pole >= pole_min * A) & (top - bot <= retrace * pole)
        ok[:WINDOW] = False
        new = ok & ~hit
        struct[new] = stop[new]
        hit |= ok
    sig, last = [], -10 ** 9
    for i in np.where(hit)[0]:
        if i - last < 5:
            continue
        sig.append((int(i), side, float(struct[i])))
        last = i
    return sig


def detect_double(x, side, tol=0.5, sep=10, neck_min=2.0, higher=False):
    """side +1 = double bottom (break up), -1 = double top (break down)."""
    h, l, c, A, ph, pl = x["h"], x["l"], x["c"], x["atr"], x["ph"], x["pl"]
    piv, opp = (pl, ph) if side == 1 else (ph, pl)
    ext = l if side == 1 else h
    sig, used = [], set()
    for i in range(WINDOW, len(c)):
        a = A[i]
        if not np.isfinite(a) or a <= 0:
            continue
        kp = piv[(piv + K <= i) & (piv >= i - WINDOW)]
        if len(kp) < 2:
            continue
        p1, p2 = kp[-2], kp[-1]
        if (p1, p2) in used or p2 - p1 < sep or i - p2 > 30 or abs(ext[p1] - ext[p2]) > tol * a:
            continue
        if higher and (side * (ext[p2] - ext[p1]) < 0):
            continue
        mids = opp[(opp + K <= i) & (opp > p1) & (opp < p2)]
        if not len(mids):
            continue
        if side == 1:
            neck, base = h[mids].max(), min(l[p1], l[p2])
            thr = neck + BUF * a
            brk = c[i] > thr and c[i - 1] <= thr
        else:
            neck, base = l[mids].min(), max(h[p1], h[p2])
            thr = neck - BUF * a
            brk = c[i] < thr and c[i - 1] >= thr
        if side * (neck - base) < neck_min * a or not brk:
            continue
        used.add((p1, p2))
        sig.append((i, side, base - side * 0.25 * a))
    return sig


# ------------------------------------------------------------------ engine
def trade(x, j0, side, R, exit_mode):
    o, h, l, c = x["o"], x["h"], x["l"], x["c"]
    n = len(c)
    entry = o[j0]
    sl = entry - side * R
    tp = entry + side * exit_mode * R if isinstance(exit_mode, float) else None
    best = 0.0
    for j in range(j0, n):
        if side == 1:
            if o[j] <= sl: return j, o[j], "stop", best
            if l[j] <= sl: return j, sl, "stop", best
            if tp is not None and o[j] >= tp: return j, o[j], "tp", best
            if tp is not None and h[j] >= tp: return j, tp, "tp", best
        else:
            if o[j] >= sl: return j, o[j], "stop", best
            if h[j] >= sl: return j, sl, "stop", best
            if tp is not None and o[j] <= tp: return j, o[j], "tp", best
            if tp is not None and l[j] <= tp: return j, tp, "tp", best
        best = max(best, (h[j] - entry) / R if side == 1 else (entry - l[j]) / R)
        if exit_mode == "T3":
            k = math.floor(best)
            if k >= 3:
                lock = (k - 3) + (0.1 if k == 3 else 0.0)
                new = entry + side * lock * R
                sl = max(sl, new) if side == 1 else min(sl, new)
    return n - 1, c[n - 1], "open", best


def simulate(x, sigs, stop, exit_mode, trend=False):
    out, free = [], 0
    c, atr, sma = x["c"], x["atr"], x["sma"]
    for i, side, struct in sigs:
        if i < free or i + 1 >= len(c):
            continue
        if trend and not (np.isfinite(sma[i]) and side * (c[i] - sma[i]) > 0):
            continue
        entry = x["o"][i + 1]
        if stop == "struct":
            R = abs(entry - struct)
            if not (0.5 * atr[i] <= R <= 4 * atr[i]) or side * (struct - entry) >= 0:
                continue
        else:
            R = 2.0 * atr[i]
        if not (np.isfinite(R) and R > 0):
            continue
        j, px, reason, best = trade(x, i + 1, side, R, exit_mode)
        cost = x["spread"][i + 1] + (STOP_SLIP if reason == "stop" else 0.0)
        out.append({"entry_time": x["t"][i + 1], "exit_time": x["t"][j], "side": side, "entry": entry, "exit": px,
                    "R_usd": R, "net_R": (side * (px - entry) - cost) / R, "reason": reason, "max_R": best,
                    "bars": j - i})
        free = j + 1
    return out


def stats(T):
    if len(T) == 0:
        return None
    r = T.net_R.values
    w, ls = r[r > 0], r[r <= 0]
    eq = np.concatenate([[0], T.sort_values("exit_time").net_R.cumsum().values])
    streak = cur = 0
    for v in T.sort_values("exit_time").net_R.values:
        cur = cur + 1 if v <= 0 else 0
        streak = max(streak, cur)
    return {"trades": len(r), "win_pct": 100 * len(w) / len(r), "avg_r": r.mean(),
            "pf": w.sum() / -ls.sum() if ls.sum() < 0 else np.inf, "total_r": r.sum(),
            "max_dd_r": (np.maximum.accumulate(eq) - eq).max(), "lose_streak": streak,
            "avg_bars": T.bars.mean(), "avg_risk_usd": T.R_usd.mean()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", default="backtest/results")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    rows, all_t = [], []
    rng = np.random.default_rng(9)
    for tf, rule in (("H1", None), ("H4", "4h")):
        df = load(a.csv, rule)
        x = context(df)
        setups = {
            "Bear flag (short)": detect_flag(x, -1),
            "Bull flag (long)": detect_flag(x, 1),
            "Double bottom (long)": detect_double(x, 1),
            "Double bottom higher (long)": detect_double(x, 1, higher=True),
            "Double top (short)": detect_double(x, -1),
        }
        r = rng.random(len(df))
        setups["RANDOM long"] = [(int(i), 1, np.nan) for i in np.where(r < 0.01)[0] if i >= WINDOW]
        setups["RANDOM short"] = [(int(i), -1, np.nan) for i in np.where(r > 0.99)[0] if i >= WINDOW]
        cut = df.index[int(len(df) * 0.6)]
        for name, sigs in setups.items():
            for trend in (False, True):
                if name.startswith("RANDOM") and trend:
                    continue
                for stop in ("atr2", "struct"):
                    if name.startswith("RANDOM") and stop == "struct":
                        continue
                    for ex_mode, ex_name in ((2.5, "TP 2.5R"), (3.0, "TP 3R"), ("T3", "Trailing 3R")):
                        T = pd.DataFrame(simulate(x, sigs, stop, ex_mode, trend))
                        s = stats(T)
                        if not s:
                            continue
                        o = stats(T[T.entry_time > cut])
                        yr = T.groupby(T.entry_time.dt.year).net_R.sum()
                        rows.append({"tf": tf, "setup": name, "trend_filter": "SMA200" if trend else "-",
                                     "stop": stop, "exit": ex_name, **s,
                                     "oos_trades": o["trades"] if o else 0, "oos_pf": o["pf"] if o else np.nan,
                                     "years_positive": f"{int((yr > 0).sum())}/{len(yr)}"})
                        T["tf"], T["setup"], T["trend"], T["stop"], T["exit_mode"] = tf, name, trend, stop, ex_name
                        all_t.append(T)
        print(f"{tf}: {len(df)} candles {df.index[0]} .. {df.index[-1]}, OOS from {cut}", flush=True)
    res = pd.DataFrame(rows)
    res.to_csv(os.path.join(a.out, "gold_summary.csv"), index=False)
    pd.concat(all_t).to_csv(os.path.join(a.out, "gold_trades.csv"), index=False)
    pd.set_option("display.width", 260)
    pd.set_option("display.max_rows", 400)
    print(res.round(2).to_string(index=False))


if __name__ == "__main__":
    main()
