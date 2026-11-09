"""Breakout backtest on every Hyperliquid perp with a 3R-lagging trailing stop.

Exit rule (no take profit):
  * initial stop = entry -/+ 2 x ATR(14)  ->  1R = 2 x ATR
  * when price reaches +3R the stop moves to entry + 0.1R (breakeven plus)
  * at +4R the stop moves to +1R, at +5R to +2R ... always 3R behind the best level
  * the trade only ends when the stop is hit

Signals are computed on a closed candle and filled at the next candle's open.
Costs: taker fee + slippage on both sides and an hourly funding charge.

Usage: python backtest/breakout_bt.py --interval 4h
"""
import argparse
import json
import math
import os

import numpy as np
import pandas as pd

FEE = 0.00045          # Hyperliquid taker fee per side (base tier)
SLIP = 0.0003          # slippage per side on a liquid market
STOP_SLIP = 0.0005     # extra slippage on stop exits
FUNDING_H = 0.0000125  # 0.00125 %/hour (0.01 %/8h baseline), charged to every trade
ATR_MULT = 2.0
MIN_ADV = 5_000_000    # min 30-day average daily notional volume (USD) at signal time
BARS_PER_DAY = {"1h": 24, "4h": 6, "1d": 1}
HOURS = {"1h": 1, "4h": 4, "1d": 24}


# ------------------------------------------------------------------ data
def load(interval, root):
    uni = json.load(open(os.path.join(root, "universe.json")))
    out = {}
    for u in uni:
        p = os.path.join(root, interval, u["coin"].replace("/", "_") + ".json")
        if not os.path.exists(p):
            continue
        rows = json.load(open(p))
        if len(rows) < 260:
            continue
        df = pd.DataFrame(rows)
        df = df[["t", "o", "h", "l", "c", "v"]].astype(float)
        df["t"] = pd.to_datetime(df["t"], unit="ms", utc=True)
        df = df.drop_duplicates("t").set_index("t").sort_index()
        out[u["coin"]] = (df, u["delisted"])
    return out


def features(df, bpd):
    f = pd.DataFrame(index=df.index)
    h, l, c, v = df.h, df.l, df.c, df.v
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    f["atr"] = tr.rolling(14).mean()
    f["atr100"] = tr.rolling(100).mean()
    f["dh20"] = h.shift(1).rolling(20).max()
    f["dl20"] = l.shift(1).rolling(20).min()
    f["dh30"] = h.shift(1).rolling(30).max()
    f["dl30"] = l.shift(1).rolling(30).min()
    f["sma200"] = c.rolling(200).mean()
    f["volr"] = v / v.shift(1).rolling(20).mean()
    f["adv"] = (v * c).rolling(30 * bpd).mean() * bpd
    bbw = 4 * c.rolling(20).std() / c.rolling(20).mean()
    f["bbpct"] = bbw.rolling(120).rank(pct=True)
    f["squeeze"] = f["bbpct"].rolling(5).min() < 0.20
    f["base"] = (f["dh30"] - f["dl30"]) / f["atr100"] <= 5.0
    return f


# ------------------------------------------------------------------ signals
def signals(df, f, pattern, vol_filter, trend_filter, rng=None, p_rand=0.0):
    c = df.c
    liquid = f["adv"] >= MIN_ADV
    ready = f["sma200"].notna() & f["bbpct"].notna() & f["atr"].notna()
    if pattern == "DONCHIAN":
        L, S = c > f.dh20, c < f.dl20
    elif pattern == "SQUEEZE":
        L, S = f["squeeze"] & (c > f.dh20), f["squeeze"] & (c < f.dl20)
    elif pattern == "BASE":
        L, S = f["base"] & (c > f.dh30), f["base"] & (c < f.dl30)
    elif pattern == "RANDOM":
        r = rng.random(len(df))
        L = pd.Series(r < p_rand / 2, index=df.index)
        S = pd.Series((r >= p_rand / 2) & (r < p_rand), index=df.index)
    else:
        raise ValueError(pattern)
    if vol_filter:
        L, S = L & (f.volr >= 1.5), S & (f.volr >= 1.5)
    if trend_filter:
        L, S = L & (c > f.sma200), S & (c < f.sma200)
    base = liquid & ready
    return (L & base).values, (S & base).values


# ------------------------------------------------------------------ trade engine
def simulate(coin, df, f, longs, shorts, interval):
    o, h, l, c = df.o.values, df.h.values, df.l.values, df.c.values
    atr = f.atr.values
    times = df.index
    n = len(df)
    trades = []
    i = 0
    while i < n - 1:
        side = 1 if longs[i] else (-1 if shorts[i] else 0)
        if side == 0 or not np.isfinite(atr[i]) or atr[i] <= 0:
            i += 1
            continue
        j0 = i + 1
        entry = o[j0]
        R = ATR_MULT * atr[i]
        sl = entry - side * R
        best = 0.0
        exit_px, exit_j, reason = None, None, None
        for j in range(j0, n):
            # 1) stop check with the stop that was valid at the start of this candle
            if side == 1:
                if o[j] <= sl:
                    exit_px, exit_j, reason = o[j], j, "gap"
                elif l[j] <= sl:
                    exit_px, exit_j, reason = sl, j, "stop"
            else:
                if o[j] >= sl:
                    exit_px, exit_j, reason = o[j], j, "gap"
                elif h[j] >= sl:
                    exit_px, exit_j, reason = sl, j, "stop"
            if exit_px is not None:
                break
            # 2) trail: best favourable excursion in R, stop stays 3R behind
            fav = (h[j] - entry) / R if side == 1 else (entry - l[j]) / R
            best = max(best, fav)
            k = math.floor(best)
            if k >= 3:
                lock = (k - 3) + (0.1 if k == 3 else 0.0)
                new_sl = entry + side * lock * R
                sl = max(sl, new_sl) if side == 1 else min(sl, new_sl)
        if exit_px is None:
            exit_px, exit_j, reason = c[n - 1], n - 1, "open"
        gross_R = side * (exit_px - entry) / R
        hours = (exit_j - j0 + 1) * HOURS[interval]
        cost_pct = 2 * (FEE + SLIP) + (STOP_SLIP if reason in ("stop", "gap") else 0) + FUNDING_H * hours
        net_R = gross_R - cost_pct * entry / R
        trades.append({
            "coin": coin, "side": "LONG" if side == 1 else "SHORT",
            "entry_time": times[j0], "exit_time": times[exit_j],
            "entry": entry, "exit": exit_px, "R_pct": R / entry * 100,
            "bars": exit_j - j0 + 1, "max_R": best, "gross_R": gross_R, "net_R": net_R, "reason": reason,
        })
        i = exit_j + 1                      # one position per coin at a time
    return trades


# ------------------------------------------------------------------ stats
def stats(t):
    if len(t) == 0:
        return None
    r = t.net_R.values
    wins, losses = r[r > 0], r[r <= 0]
    eq = t.sort_values("exit_time").net_R.cumsum().values
    dd = (np.maximum.accumulate(np.concatenate([[0], eq])) - np.concatenate([[0], eq])).max()
    streak = cur = 0
    for x in t.sort_values("exit_time").net_R.values:
        cur = cur + 1 if x <= 0 else 0
        streak = max(streak, cur)
    return {
        "trades": len(r),
        "win_rate_%": 100 * len(wins) / len(r),
        "avg_R": r.mean(),
        "median_R": float(np.median(r)),
        "profit_factor": wins.sum() / -losses.sum() if losses.sum() < 0 else float("inf"),
        "total_R": r.sum(),
        "max_dd_R": dd,
        "max_loss_streak": streak,
        "full_loss_%": 100 * (r <= -0.9).mean(),
        "reached_3R_%": 100 * (t.max_R >= 3).mean(),
        "ge_5R_%": 100 * (r >= 5).mean(),
        "best_R": r.max(),
        "avg_bars": t.bars.mean(),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", default="4h")
    ap.add_argument("--data", default="backtest/data")
    ap.add_argument("--out", default="backtest/results")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    data = load(a.interval, a.data)
    feats = {k: features(df, BARS_PER_DAY[a.interval]) for k, (df, _) in data.items()}
    print(f"{len(data)} coins loaded ({sum(1 for _, d in data.values() if d)} delisted)")

    variants = []
    for pat in ["DONCHIAN", "SQUEEZE", "BASE"]:
        for vf in [False, True]:
            for tf in [False, True]:
                variants.append((pat, vf, tf))
    all_trades = {}
    rng = np.random.default_rng(7)
    for pat, vf, tf in variants:
        name = f"{pat}{' +VOL' if vf else ''}{' +TREND' if tf else ''}"
        tr = []
        for coin, (df, _) in data.items():
            L, S = signals(df, feats[coin], pat, vf, tf)
            tr += simulate(coin, df, feats[coin], L, S, a.interval)
        all_trades[name] = pd.DataFrame(tr)
    # random-entry control, matched to the plain Donchian signal frequency
    base_n = len(all_trades["DONCHIAN"])
    elig = sum(int((feats[k].adv >= MIN_ADV).sum()) for k in data)
    p = min(0.5, base_n * 3 / max(elig, 1))
    tr = []
    for coin, (df, _) in data.items():
        L, S = signals(df, feats[coin], "RANDOM", False, False, rng, p)
        tr += simulate(coin, df, feats[coin], L, S, a.interval)
    all_trades["RANDOM (control)"] = pd.DataFrame(tr)

    rows = []
    for name, t in all_trades.items():
        if len(t) == 0:
            continue
        cut = t.entry_time.quantile(0.6)
        for part, sub in [("ALL", t), ("IN-SAMPLE", t[t.entry_time <= cut]), ("OUT-OF-SAMPLE", t[t.entry_time > cut])]:
            s = stats(sub)
            if s:
                rows.append({"strategy": name, "period": part, **s})
        for side in ["LONG", "SHORT"]:
            s = stats(t[t.side == side])
            if s:
                rows.append({"strategy": name, "period": side, **s})
        t.to_csv(os.path.join(a.out, f"trades_{a.interval}_{name.replace(' ', '').replace('+', '_').replace('(', '').replace(')', '')}.csv"), index=False)
    res = pd.DataFrame(rows)
    res.to_csv(os.path.join(a.out, f"summary_{a.interval}.csv"), index=False)
    span = (min(df.index[0] for df, _ in data.values()), max(df.index[-1] for df, _ in data.values()))
    print(f"period {span[0]:%Y-%m-%d} .. {span[1]:%Y-%m-%d}")
    pd.set_option("display.width", 250)
    pd.set_option("display.max_columns", 30)
    print(res[res.period == "ALL"].round(2).to_string(index=False))
    print()
    print(res[res.period.isin(["OUT-OF-SAMPLE", "LONG", "SHORT"])].round(2).to_string(index=False))


if __name__ == "__main__":
    main()
