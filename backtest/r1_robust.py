"""Rank R1 variants by the WORSE of in-sample and out-of-sample profit factor.

Run: python3 backtest/r1_robust.py
A variant only scores well if it works in both halves of the data.
"""
import itertools, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m
from r1_optimize import evaluate, slice_data, COINS

full = {c: m.load(c) for c in COINS}
n = len(full[COINS[0]]["t"]); cut = int(n * 0.6)
IS = {c: slice_data(full[c], 0, cut) for c in COINS}
OOS = {c: slice_data(full[c], cut - 250, n) for c in COINS}
base = dict(m.RULES["R1 Classic breakout"])
grid = dict(piv=[3, 5, 7], tol=[0.3, 0.5, 0.8], min_gap=[5, 10, 20], min_depth=[1.0, 1.5, 2.0, 3.0],
            sl_buf=[0.1, 0.25, 0.5], rr=[2.5, 3.0], trend=[False, True],
            session=[None, (7, 20), (12, 21)], body=[0, 0.3, 0.6])
keys = list(grid); res = []
for combo in itertools.product(*grid.values()):
    r = dict(base, **dict(zip(keys, combo)))
    a = evaluate(IS, r)
    if a["n"] < 10: continue
    b = evaluate(OOS, r)
    if b["n"] < 8: continue
    res.append((min(a["pf"], b["pf"]), a, b, r))
res.sort(key=lambda x: -x[0])
print(f"{len(res)} variants with >=10 IS and >=8 OOS trades\n")
for score, a, b, r in res[:12]:
    f = evaluate(full, r)
    print({k: r[k] for k in keys})
    print(f"   IS  n={a['n']:3} pf={a['pf']:.2f} tot={a['total']:6.2f} | OOS n={b['n']:3} pf={b['pf']:.2f} tot={b['total']:6.2f} | FULL n={f['n']} win={f['win']:.0f}% pf={f['pf']:.2f} tot={f['total']:.2f} dd={f['dd']:.2f}")
good = sum(1 for x in res if x[0] > 1.2)
print(f"\nVariants with PF>1.2 in BOTH halves: {good} of {len(res)}")
