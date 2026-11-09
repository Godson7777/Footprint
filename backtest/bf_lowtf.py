"""Bear flag on lower timeframes with years of Binance futures history.

Same rules, entry, stop, trailing exit and costs as explore_bt.py (Hyperliquid fees kept,
so results are conservative for a Hyperliquid trader). Detection is vectorized and is
checked against explore_bt.detect_bf on Hyperliquid 1h data (must give identical signals).

Usage: python backtest/bf_lowtf.py --sets bn1h bn15m hl1h --min-adv 50e6
"""
import argparse
import json
import os

import numpy as np
import pandas as pd

import breakout_bt as bt
import explore_bt as ex

bt.HOURS.update({"bn1h": 1, "bn15m": 0.25, "hl1h": 1})
BPD = {"bn1h": 24, "bn15m": 96, "hl1h": 24}
VARIANTS = [
    ("baseline (pole >= 4 ATR)", dict(pole=4.0, trend=False, exit="T3")),
    ("pole >= 3 ATR", dict(pole=3.0, trend=False, exit="T3")),
    ("ROBUST pole3 + below SMA200", dict(pole=3.0, trend=True, exit="T3")),
    ("ROBUST pole3 + below SMA200, TP 3R", dict(pole=3.0, trend=True, exit="TP3")),
]


def detect_bf_vec(h, l, c, atr, pole_min, pause_max=15, retrace=0.5):
    """Vectorized copy of explore_bt.detect_bf. Returns [(i, -1, struct_stop)]."""
    n = len(c)
    H, L, C = pd.Series(h), pd.Series(l), pd.Series(c)
    A = atr
    hit = np.zeros(n, bool)
    struct = np.full(n, np.nan)
    for m in (5, 8, 12, 15):
        if m > pause_max:
            break
        pole = C.shift(m + 11).values - C.shift(m + 1).values
        top = H.rolling(m).max().shift(1).values
        bot = L.rolling(m).min().shift(1).values
        prior = L.rolling(11).min().shift(m + 1).values   # l[s-11:s]
        cs = C.shift(m).values
        thr = bot - ex.BUF * A
        with np.errstate(invalid="ignore"):
            ok = (np.isfinite(A) & (A > 0) & (pole >= pole_min * A) & (top - bot <= retrace * pole)
                  & (bot >= prior - 0.25 * A) & (C.shift(1).values >= cs)
                  & (c < thr) & (C.shift(1).values >= thr))
        ok[:ex.WINDOW] = False
        new = ok & ~hit
        struct[new] = top[new] + 0.25 * A[new]
        hit |= ok
    sig, last = [], -10 ** 9
    for i in np.where(hit)[0]:
        if i - last < 5:
            continue
        sig.append((int(i), -1, float(struct[i])))
        last = i
    return sig


def load_set(name, data_root, min_adv):
    ctxs = []
    if name.startswith("bn"):
        folder = os.path.join(data_root, name)
        for f in sorted(os.listdir(folder)):
            z = np.load(os.path.join(folder, f))
            if len(z["t"]) < 300:
                continue
            df = pd.DataFrame({k: z[k] for k in ["o", "h", "l", "c", "v", "qv"]},
                              index=pd.to_datetime(z["t"], unit="ms", utc=True))
            ctxs.append((f[:-4], df))
    else:
        for coin, (df, _) in bt.load("1h", data_root).items():
            df = df.copy()
            df["qv"] = df.v * df.c
            ctxs.append((coin, df))
    out = []
    bpd = BPD[name]
    for coin, df in ctxs:
        h, l, c = df.h, df.l, df.c
        tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
        atr = tr.rolling(14).mean()
        adv = df.qv.rolling(30 * bpd).mean() * bpd
        out.append({"coin": coin, "o": df.o.values, "h": h.values, "l": l.values, "c": c.values, "t": df.index,
                    "atr": atr.values, "sma": c.rolling(200).mean().values,
                    "volr": (df.v / df.v.shift(1).rolling(20).mean()).values,
                    "liquid": ((adv >= min_adv) & atr.notna()).values})
    return out


def verify_against_loop(data_root):
    """Vectorized detector must reproduce explore_bt.detect_bf exactly on HL 1h."""
    ctxs = load_set("hl1h", data_root, 0)
    for x in ctxs:
        for pole in (3.0, 4.0):
            a = ex.detect_bf(x, {**ex.BF_BASE, "pole": pole})
            b = detect_bf_vec(x["h"], x["l"], x["c"], x["atr"], pole)
            if [(i, round(s, 9)) for i, _, s in a] != [(i, round(s, 9)) for i, _, s in b]:
                raise SystemExit(f"MISMATCH {x['coin']} pole {pole}: loop {a[:3]} vs vec {b[:3]}")
    print(f"verified: vectorized detector == loop detector on {len(ctxs)} HL 1h coins")


def run(name, data_root, min_adv, rng):
    ctxs = load_set(name, data_root, min_adv)
    rows, trades = [], []
    for label, v in VARIANTS:
        p = {**ex.BF_BASE, **v}
        tt = []
        for x in ctxs:
            sigs = detect_bf_vec(x["h"], x["l"], x["c"], x["atr"], p["pole"])
            for t in ex.simulate(x, sigs, p, name, x["liquid"]):
                t.update(coin=x["coin"], variant=label, set=name)
                tt.append(t)
        trades += tt
    tt = []
    for x in ctxs:                                # random short control
        r = rng.random(len(x["c"]))
        sigs = [(int(i), -1, np.nan) for i in np.where(r < 0.0025)[0] if i >= ex.WINDOW]
        for t in ex.simulate(x, sigs, {**ex.BF_BASE}, name, x["liquid"]):
            t.update(coin=x["coin"], variant="RANDOM short", set=name)
            tt.append(t)
    trades += tt
    T = pd.DataFrame(trades)
    cut = T.entry_time.quantile(0.6)
    for var, g in T.groupby("variant", sort=False):
        s = bt.stats(g)
        o = bt.stats(g[g.entry_time > cut])
        yr = g.groupby(g.entry_time.dt.year).net_R.sum().round(1).to_dict()
        rows.append({"set": name, "variant": var, "trades": s["trades"], "win_pct": s["win_rate_%"], "avg_r": s["avg_R"],
                     "pf": s["profit_factor"], "total_r": s["total_R"], "max_dd_r": s["max_dd_R"],
                     "lose_streak": s["max_loss_streak"], "oos_n": o["trades"], "oos_pf": o["profit_factor"],
                     "coins": g.coin.nunique(), "first": g.entry_time.min().date(), "last": g.entry_time.max().date(),
                     "R_by_year": json.dumps(yr)})
    return rows, T


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", nargs="+", default=["bn1h", "bn15m", "hl1h"])
    ap.add_argument("--min-adv", type=float, default=50e6, help="min 30d avg daily USD volume (Binance scale)")
    ap.add_argument("--hl-min-adv", type=float, default=bt.MIN_ADV)
    ap.add_argument("--data", default="backtest/data")
    ap.add_argument("--out", default="backtest/results")
    ap.add_argument("--verify", action="store_true")
    a = ap.parse_args()
    if a.verify:
        verify_against_loop(a.data)
    rng = np.random.default_rng(3)
    rows = []
    for s in a.sets:
        r, T = run(s, a.data, a.hl_min_adv if s == "hl1h" else a.min_adv, rng)
        rows += r
        T.to_csv(os.path.join(a.out, f"bf_lowtf_trades_{s}.csv"), index=False)
        print(f"done {s}", flush=True)
    res = pd.DataFrame(rows)
    res.to_csv(os.path.join(a.out, "bf_lowtf_summary.csv"), index=False)
    pd.set_option("display.width", 250)
    pd.set_option("display.max_colwidth", 120)
    print(res.round(2).to_string(index=False))


if __name__ == "__main__":
    main()
