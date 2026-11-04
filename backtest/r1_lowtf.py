"""R1 Trend (trend EMA + pivot 7, RR 2.5) on lower timeframes for gold.

Run: python3 backtest/r1_lowtf.py
Data: Hyperliquid xyz:GOLD + PAXG (M30 ~3.4 mo, M15 ~1.7 mo) and Yahoo GC=F (60 days).
Two versions per timeframe:
- same:   same numbers of candles as H1 (pattern is smaller in hours)
- scaled: candle counts x factor so the pattern spans the same hours as H1
H1 over the SAME dates is shown for comparison, because recent months were weak on H1 too.
"""
import json, os, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m
from r1_optimize import run_ext

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = sys.argv[1] if len(sys.argv) > 1 else None


def load_rows(rows, ema_n):
    d = {k: [r[i] for r in rows] for i, k in enumerate("tohlc")}
    d["atr"], d["rsi"], d["ema200"] = m.atr(d["h"], d["l"], d["c"]), m.rsi(d["c"]), m.ema(d["c"], ema_n)
    return d


def load(name, ema_n):
    return load_rows(json.load(open(os.path.join(HERE, "data", name))), ema_n)


BASE = dict(m.RULES["R1 Classic breakout"], trend=True, piv=7, rr=2.5)


def scaled(f):
    return dict(BASE, piv=7 * f, min_gap=10 * f, max_gap=80 * f, brk_win=24 * f, max_hold=96 * f)


def show(label, sets, r, since=None):
    tr = []
    for d in sets:
        tr += [t for t in run_ext(d, r) if since is None or t["t"] >= since]
    tr.sort(key=lambda x: x["t"])
    s = m.stats(tr)
    if not s["n"]:
        print(f"  {label:34} n=0"); return
    days = (max(d["t"][-1] for d in sets) - (since or min(d["t"][0] for d in sets))) / 864e5
    print(f"  {label:34} n={s['n']:3} /bln/market={s['n']/len(sets)/(days/30.4):4.1f} win={s['win']:3.0f}% "
          f"pf={s['pf']:.2f} tot={s['total']:6.2f}R dd={s['dd']:6.2f}")


for iv, f in (("30m", 2), ("15m", 4)):
    hl = [load(f"{c}_{iv}.json", 200) for c in ("xyz_GOLD", "PAXG")]
    hl_s = [load(f"{c}_{iv}.json", 200 * f) for c in ("xyz_GOLD", "PAXG")]
    since = hl[0]["t"][0] + 200 * f * (900e3 if iv == "15m" else 1800e3)  # skip EMA warm-up
    print(f"\n=== {iv} Hyperliquid xyz:GOLD + PAXG ===")
    show("same candles", hl, BASE, since)
    show(f"scaled x{f} (same hours as H1)", hl_s, scaled(f), since)
    h1 = [load(f"{c}_1h.json", 200) for c in ("xyz_GOLD", "PAXG")]
    show("H1 reference, same dates", h1, BASE, since)
    g = [load("GC_1h.json", 200)]
    show("H1 GC=F, same dates", g, BASE, since)
