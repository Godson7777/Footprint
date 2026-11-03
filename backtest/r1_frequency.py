"""More frequent R1+ variants on gold: looser H1 rules, and the same rules on M30 / M15.

Run: python3 backtest/r1_frequency.py
Pattern sizes are in candles, so on M30/M15 the pattern is shorter in hours.
Reports trades per month, first half vs second half profit factor.
"""
import json, os, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m
from r1_optimize import run_ext

HERE = os.path.dirname(os.path.abspath(__file__))
COINS = ["xyz_GOLD", "PAXG"]


def load(coin, iv):
    rows = json.load(open(os.path.join(HERE, "data", f"{coin}_{iv}.json")))
    d = {k: [r[i] for r in rows] for i, k in enumerate("tohlc")}
    d["atr"], d["rsi"], d["ema200"] = m.atr(d["h"], d["l"], d["c"]), m.rsi(d["c"]), m.ema(d["c"], 200)
    return d


def evalp(data, r, since=None):
    tr = []
    for c in COINS:
        tr += [t for t in run_ext(data[c], r) if since is None or t["t"] >= since]
    tr.sort(key=lambda x: x["t"])
    return tr


def line(label, tr, months):
    s = m.stats(tr)
    if not s["n"]:
        print(f"{label:42} n=0"); return
    h = len(tr) // 2
    a, b = m.stats(tr[:h]), m.stats(tr[h:])
    # per coin trades/month (count one market only = what a trader on one chart sees)
    print(f"{label:42} n={s['n']:3} /bln/market={s['n']/len(COINS)/months:4.1f} win={s['win']:3.0f}% "
          f"pf={s['pf']:.2f} tot={s['total']:6.2f}R dd={s['dd']:6.2f} | pf 1st half={a['pf']:.2f} 2nd={b['pf']:.2f}")


R1P = dict(m.RULES["R1 Classic breakout"], session=(7, 20), rr=3.0)
variants = {
    "R1+ (baseline)": R1P,
    "piv3": dict(R1P, piv=3),
    "piv3 gap5": dict(R1P, piv=3, min_gap=5),
    "piv3 gap5 tol0.8": dict(R1P, piv=3, min_gap=5, tol=0.8),
    "piv4 gap6 depth1.0": dict(R1P, piv=4, min_gap=6, min_depth=1.0),
    "no session": dict(R1P, session=None),
}
for iv, months_full in (("1h", 6.8), ("30m", 3.4), ("15m", 1.7)):
    data = {c: load(c, iv) for c in COINS}
    print(f"\n=== {iv} (~{months_full} months of data) ===")
    for name, r in variants.items():
        line(name, evalp(data, r), months_full)
