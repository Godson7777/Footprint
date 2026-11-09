"""Rule exploration for DOUBLE BOTTOM (long) and BEAR FLAG (short), plus counter positions.

Method: start from a baseline rule set, then change ONE rule at a time so the
effect of every rule is visible on its own (less curve fitting than a full grid).
Each variant is compared with random entries in the same direction on the same
timeframe, using the same stop, exit and costs.

Exit modes
  T3   user's rule: stop fixed until +3R, then entry+0.1R, +4R->+1R, +5R->+2R ... (3R behind)
  T2   breakeven+ at +2R, then 2R behind (+3R->+1R, +4R->+2R ...)
  TP3  fixed take profit at +3R, otherwise the stop

Counter position (after the breakout trade is stopped at its INITIAL stop):
  SAR      reverse at the next candle's open
  CONFIRM  reverse only if the stop candle CLOSED beyond the stop level
  Counter trades use a 2 x ATR stop and the same exit mode.

Usage: python backtest/explore_bt.py --intervals 1h 4h 1d
"""
import argparse
import math
import os

import numpy as np
import pandas as pd

import breakout_bt as bt
from patterns_bt import pivots, K

WINDOW, BUF = 100, 0.1

DB_BASE = dict(tol=0.5, sep=10, neck=2.0, higher_low=False, rsi_div=False, vol=0.0, trend=False,
               max_ext=30, stop="atr2", exit="T3", counter="none")
BF_BASE = dict(pole=4.0, pause_max=15, retrace=0.5, vol=0.0, trend=False,
               stop="atr2", exit="T3", counter="none")

DB_VARIANTS = [("baseline", {}),
               ("tol 0.25 ATR", {"tol": 0.25}), ("tol 1.0 ATR", {"tol": 1.0}),
               ("sep >= 5", {"sep": 5}), ("sep >= 20", {"sep": 20}),
               ("neck >= 1.5 ATR", {"neck": 1.5}), ("neck >= 3 ATR", {"neck": 3.0}),
               ("2nd bottom higher", {"higher_low": True}), ("RSI divergence", {"rsi_div": True}),
               ("volume >= 1.5x", {"vol": 1.5}), ("trend > SMA200", {"trend": True}),
               ("fresh (<=10 bars)", {"max_ext": 10}),
               ("stop 1.5 ATR", {"stop": "atr1.5"}), ("stop structural", {"stop": "struct"}),
               ("exit T2", {"exit": "T2"}), ("exit TP3", {"exit": "TP3"}),
               ("counter SAR", {"counter": "sar"}), ("counter CONFIRM", {"counter": "confirm"}),
               # combinations chosen on 4H results, validated on 1H / 1D
               ("COMBO tol0.25+higher", {"tol": 0.25, "higher_low": True}),
               ("COMBO tol0.25+vol", {"tol": 0.25, "vol": 1.5}),
               ("COMBO tol0.25+higher+vol", {"tol": 0.25, "higher_low": True, "vol": 1.5})]
BF_VARIANTS = [("baseline", {}),
               ("pole >= 3 ATR", {"pole": 3.0}), ("pole >= 5 ATR", {"pole": 5.0}),
               ("pause <= 8 bars", {"pause_max": 8}), ("retrace <= 38%", {"retrace": 0.38}),
               ("volume >= 1.5x", {"vol": 1.5}), ("trend < SMA200", {"trend": True}),
               ("stop 1.5 ATR", {"stop": "atr1.5"}), ("stop structural", {"stop": "struct"}),
               ("exit T2", {"exit": "T2"}), ("exit TP3", {"exit": "TP3"}),
               ("counter SAR", {"counter": "sar"}), ("counter CONFIRM", {"counter": "confirm"}),
               # combinations chosen on 4H results, validated on 1H / 1D
               ("COMBO pause8+retr38", {"pause_max": 8, "retrace": 0.38}),
               ("COMBO pause8+retr38+struct", {"pause_max": 8, "retrace": 0.38, "stop": "struct"}),
               ("COMBO retr38+vol+struct", {"retrace": 0.38, "vol": 1.5, "stop": "struct"})]


def rsi(c, n=14):
    d = np.diff(c, prepend=c[0])
    up = pd.Series(np.clip(d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    dn = pd.Series(np.clip(-d, 0, None)).ewm(alpha=1 / n, adjust=False).mean()
    return (100 - 100 / (1 + up / dn.replace(0, np.nan))).values


# ------------------------------------------------------------------ detection
def detect_db(ctx, p):
    h, l, c, atr, ph, pl = ctx["h"], ctx["l"], ctx["c"], ctx["atr"], ctx["ph"], ctx["pl"]
    sig = []
    used = set()
    for i in range(WINDOW, len(c)):
        A = atr[i]
        if not np.isfinite(A) or A <= 0:
            continue
        kl = pl[(pl + K <= i) & (pl >= i - WINDOW)]
        if len(kl) < 2:
            continue
        p1, p2 = kl[-2], kl[-1]
        if (p1, p2) in used or p2 - p1 < p["sep"] or i - p2 > p["max_ext"]:
            continue
        if abs(l[p1] - l[p2]) > p["tol"] * A or (p["higher_low"] and l[p2] < l[p1]):
            continue
        if p["rsi_div"] and not (ctx["rsi"][p2] > ctx["rsi"][p1]):
            continue
        kh = ph[(ph + K <= i) & (ph > p1) & (ph < p2)]
        if not len(kh):
            continue
        neck = h[kh].max()
        bottom = min(l[p1], l[p2])
        if neck - bottom < p["neck"] * A:
            continue
        thr = neck + BUF * A
        if c[i] > thr and c[i - 1] <= thr:
            used.add((p1, p2))
            sig.append((i, 1, bottom - 0.25 * A))
    return sig


def detect_bf(ctx, p):
    h, l, c, atr = ctx["h"], ctx["l"], ctx["c"], ctx["atr"]
    sig = []
    last = -10 ** 9
    for i in range(WINDOW, len(c)):
        A = atr[i]
        if not np.isfinite(A) or A <= 0 or i - last < 5:
            continue
        for m in (5, 8, 12, 15):
            if m > p["pause_max"]:
                break
            s = i - m
            pole = c[s - 11] - c[s - 1]                    # drop size (positive for a bear pole)
            if pole < p["pole"] * A:
                continue
            top, bot = h[s:i].max(), l[s:i].min()
            if top - bot > p["retrace"] * pole or bot < l[s - 11:s].min() - 0.25 * A or c[i - 1] < c[s]:
                continue
            thr = bot - BUF * A
            if c[i] < thr and c[i - 1] >= thr:
                sig.append((i, -1, top + 0.25 * A))
                last = i
                break
    return sig


# ------------------------------------------------------------------ engine
def run_trade(ctx, j0, side, sl, R, mode, interval):
    o, h, l, c = ctx["o"], ctx["h"], ctx["l"], ctx["c"]
    n = len(c)
    entry = o[j0]
    init_sl = sl
    best = 0.0
    tp = entry + side * 3 * R if mode == "TP3" else None
    lag = 2 if mode == "T2" else 3
    for j in range(j0, n):
        if side == 1:
            if o[j] <= sl: return finish(ctx, j0, j, side, entry, o[j], R, "gap", sl == init_sl, best, interval)
            if l[j] <= sl: return finish(ctx, j0, j, side, entry, sl, R, "stop", sl == init_sl, best, interval)
            if tp and h[j] >= tp: return finish(ctx, j0, j, side, entry, max(tp, o[j]), R, "tp", False, best, interval)
        else:
            if o[j] >= sl: return finish(ctx, j0, j, side, entry, o[j], R, "gap", sl == init_sl, best, interval)
            if h[j] >= sl: return finish(ctx, j0, j, side, entry, sl, R, "stop", sl == init_sl, best, interval)
            if tp and l[j] <= tp: return finish(ctx, j0, j, side, entry, min(tp, o[j]), R, "tp", False, best, interval)
        fav = (h[j] - entry) / R if side == 1 else (entry - l[j]) / R
        best = max(best, fav)
        if mode in ("T3", "T2"):
            k = math.floor(best)
            if k >= lag:
                lock = (k - lag) + (0.1 if k == lag else 0.0)
                new = entry + side * lock * R
                sl = max(sl, new) if side == 1 else min(sl, new)
    return finish(ctx, j0, n - 1, side, entry, c[n - 1], R, "open", False, best, interval)


def finish(ctx, j0, j, side, entry, px, R, reason, initial, best, interval):
    hours = (j - j0 + 1) * bt.HOURS[interval]
    cost = 2 * (bt.FEE + bt.SLIP) + (bt.STOP_SLIP if reason in ("stop", "gap") else 0) + bt.FUNDING_H * hours
    gross = side * (px - entry) / R
    return {"entry_i": j0, "exit_i": j, "side": side, "net_R": gross - cost * entry / R, "gross_R": gross,
            "reason": reason, "initial_stop": initial and reason in ("stop", "gap"), "max_R": best,
            "entry_time": ctx["t"][j0], "exit_time": ctx["t"][j], "bars": j - j0 + 1}


def simulate(ctx, sigs, p, interval, liquid):
    out = []
    atr, c = ctx["atr"], ctx["c"]
    free_from = 0
    for i, side, struct in sigs:
        if i < free_from or i + 1 >= len(c) or not liquid[i]:
            continue
        if p.get("vol") and ctx["volr"][i] < p["vol"]:
            continue
        if p.get("trend") and ((side == 1 and not c[i] > ctx["sma"][i]) or (side == -1 and not c[i] < ctx["sma"][i])):
            continue
        entry = ctx["o"][i + 1]
        if p["stop"] == "struct":
            R = abs(entry - struct)
            if not (0.5 * atr[i] <= R <= 4 * atr[i]) or (struct - entry) * side >= 0:
                continue
        else:
            R = (1.5 if p["stop"] == "atr1.5" else 2.0) * atr[i]
        t = run_trade(ctx, i + 1, side, entry - side * R, R, p["exit"], interval)
        t["role"] = "main"
        out.append(t)
        free_from = t["exit_i"] + 1
        # counter position after a failed breakout
        if p["counter"] != "none" and t["initial_stop"] and t["exit_i"] + 1 < len(c):
            j = t["exit_i"]
            ok = True
            if p["counter"] == "confirm":
                stop_px = entry - side * R
                ok = (c[j] < stop_px) if side == 1 else (c[j] > stop_px)
            if ok and np.isfinite(atr[j]) and atr[j] > 0:
                R2 = 2.0 * atr[j]
                e2 = ctx["o"][j + 1]
                t2 = run_trade(ctx, j + 1, -side, e2 + side * R2, R2, p["exit"], interval)
                t2["role"] = "counter"
                out.append(t2)
                free_from = t2["exit_i"] + 1
    return out


def summarize(t, cut):
    if len(t) == 0:
        return {"trades": 0}
    s = bt.stats(t)
    o = bt.stats(t[t.entry_time > cut])
    return {"trades": s["trades"], "win%": s["win_rate_%"], "avg_R": s["avg_R"], "PF": s["profit_factor"],
            "total_R": s["total_R"], "maxDD_R": s["max_dd_R"], "lose_streak": s["max_loss_streak"],
            "oos_n": o["trades"] if o else 0, "oos_PF": o["profit_factor"] if o else np.nan}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--intervals", nargs="+", default=["1h", "4h", "1d"])
    ap.add_argument("--data", default="backtest/data")
    ap.add_argument("--out", default="backtest/results")
    a = ap.parse_args()
    rows = []
    for iv in a.intervals:
        data = bt.load(iv, a.data)
        ctxs = []
        for coin, (df, _) in data.items():
            f = bt.features(df, bt.BARS_PER_DAY[iv])
            ph, pl = pivots(df.h.values, df.l.values)
            ctxs.append({"coin": coin, "o": df.o.values, "h": df.h.values, "l": df.l.values, "c": df.c.values,
                         "t": df.index, "atr": f.atr.values, "sma": f.sma200.values, "volr": f.volr.values,
                         "rsi": rsi(df.c.values), "ph": ph, "pl": pl,
                         "liquid": ((f.adv >= bt.MIN_ADV) & f.atr.notna()).values})
        span = (min(x["t"][0] for x in ctxs), max(x["t"][-1] for x in ctxs))
        allt = []
        for pattern, base, variants, det in (("DOUBLE_BOTTOM", DB_BASE, DB_VARIANTS, detect_db),
                                             ("BEAR_FLAG", BF_BASE, BF_VARIANTS, detect_bf)):
            det_cache = {}
            for label, change in variants:
                p = {**base, **change}
                key = tuple(sorted((k, v) for k, v in p.items() if k not in ("vol", "trend", "stop", "exit", "counter")))
                trades = []
                for x in ctxs:
                    ck = (x["coin"], key)
                    if ck not in det_cache:
                        det_cache[ck] = det(x, p)
                    for t in simulate(x, det_cache[ck], p, iv, x["liquid"]):
                        t.update(coin=x["coin"], pattern=pattern, variant=label, interval=iv)
                        trades.append(t)
                allt += trades
        # random control, both directions
        rng = np.random.default_rng(5)
        for side in (1, -1):
            trades = []
            for x in ctxs:
                r = rng.random(len(x["c"]))
                sigs = [(i, side, np.nan) for i in np.where(r < 0.01)[0] if i >= WINDOW]
                for t in simulate(x, sigs, {**DB_BASE}, iv, x["liquid"]):
                    t.update(coin=x["coin"], pattern="RANDOM", variant="LONG" if side == 1 else "SHORT", interval=iv)
                    trades.append(t)
            allt += trades
        T = pd.DataFrame(allt)
        cut = T.entry_time.quantile(0.6)
        for (pat, var), g in T.groupby(["pattern", "variant"], sort=False):
            r = {"interval": iv, "pattern": pat, "variant": var, **summarize(g, cut)}
            if (g.role == "counter").any():
                cs = bt.stats(g[g.role == "counter"])
                r.update(counter_n=cs["trades"], counter_win=cs["win_rate_%"], counter_avgR=cs["avg_R"], counter_PF=cs["profit_factor"])
            rows.append(r)
        T.to_csv(os.path.join(a.out, f"explore_trades_{iv}.csv"), index=False)
        print(f"== {iv}: {len(ctxs)} coins, {span[0]:%Y-%m-%d} .. {span[1]:%Y-%m-%d}, OOS from {cut:%Y-%m-%d}", flush=True)
    res = pd.DataFrame(rows)
    res.to_csv(os.path.join(a.out, "explore_summary.csv"), index=False)
    pd.set_option("display.width", 260)
    pd.set_option("display.max_rows", 500)
    print(res.round(2).to_string(index=False))


if __name__ == "__main__":
    main()
