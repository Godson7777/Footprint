"""Grid search R1 Classic on gold with in-sample / out-of-sample split.

Run: python3 backtest/r1_optimize.py
IS = first 60% of candles, OOS = last 40%. Ranking uses IS only.
Extra filters tested on top of R1:
- session: only enter during given UTC hours
- body: breakout candle body >= x * ATR (strong break)
- max_dist: skip if entry is already > x * ATR past the neckline (late entry)
"""
import itertools, json, os, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m

HERE = os.path.dirname(os.path.abspath(__file__))
COINS = ["xyz_GOLD", "PAXG"]


def slice_data(d, a, b):
    return {k: v[a:b] for k, v in d.items()}


def run_ext(d, r):
    trades = m.run(d, r)
    out = []
    idx = {t: i for i, t in enumerate(d["t"])}
    for t in trades:
        i = idx[t["t"]]
        hr = (t["t"] // 3600000) % 24
        if r.get("session") and not (r["session"][0] <= hr < r["session"][1]):
            continue
        body = abs(d["c"][i] - d["o"][i])
        if body < r.get("body", 0) * d["atr"][i]:
            continue
        out.append(t)
    return out


def evaluate(data, r):
    allt = []
    for c in COINS:
        allt += run_ext(data[c], r)
    return m.stats(sorted(allt, key=lambda x: x["t"]))


def main():
    full = {c: m.load(c) for c in COINS}
    n = len(full[COINS[0]]["t"])
    cut = int(n * 0.6)
    IS = {c: slice_data(full[c], 0, cut) for c in COINS}
    OOS = {c: slice_data(full[c], cut - 250, n) for c in COINS}  # 250 bars warm-up for EMA/ATR

    base = dict(m.RULES["R1 Classic breakout"])
    grid = dict(
        piv=[3, 5, 7],
        tol=[0.3, 0.5, 0.8],
        min_depth=[1.0, 1.5, 2.0],
        sl_buf=[0.1, 0.25, 0.5],
        rr=[2.5, 3.0],
        trend=[False, True],
        session=[None, (7, 20)],
        body=[0, 0.5],
    )
    keys = list(grid)
    res = []
    for combo in itertools.product(*grid.values()):
        r = dict(base, **dict(zip(keys, combo)))
        s = evaluate(IS, r)
        if s["n"] >= 15:
            res.append((s["pf"], s, r))
    res.sort(key=lambda x: -x[0])
    print(f"Tested {len(res)} combos with >=15 IS trades. IS cut at {cut}/{n} candles\n")
    rows = []
    for pf, s, r in res[:15]:
        o = evaluate(OOS, r)
        f = evaluate(full, r)
        desc = {k: r[k] for k in keys}
        rows.append(dict(params=desc, IS=s, OOS=o, FULL=f))
        print(desc)
        for lab, x in (("IS", s), ("OOS", o), ("FULL", f)):
            if x["n"]:
                print(f"   {lab:4} n={x['n']:3} win={x['win']:5.1f}% tot={x['total']:6.2f}R pf={x['pf']:.2f} dd={x['dd']:.2f}")
            else:
                print(f"   {lab:4} n=0")
    b = evaluate(full, base); bo = evaluate(OOS, base)
    print(f"\nBaseline R1 FULL n={b['n']} pf={b['pf']:.2f} tot={b['total']:.2f} | OOS n={bo['n']} pf={bo['pf']:.2f} tot={bo['total']:.2f}")
    json.dump(rows, open(os.path.join(HERE, "r1_optimize_top.json"), "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
