"""Backtest double top / double bottom on H1 candles (Hyperliquid data).

Run: python3 backtest/double_top_bottom.py
Data: backtest/data/<COIN>_1h.json  rows = [time_ms, open, high, low, close]

Assumptions (conservative):
- Pivots are only used after they are confirmed (PIV bars later), no look-ahead.
- If SL and TP are both touched in the same candle, SL counts.
- Fee 0.045% per side (Hyperliquid taker) is subtracted from every trade.
- Trade closes at market after MAX_HOLD candles if neither SL nor TP was hit.
- One open trade at a time per coin.
"""
import json, os, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
import sys
COINS = sys.argv[1:] or ["BTC", "ETH", "SOL"]
FEE = 0.00045
MAX_HOLD = 96


def ema(vals, n):
    k, out, e = 2 / (n + 1), [], vals[0]
    for v in vals:
        e = v * k + e * (1 - k)
        out.append(e)
    return out


def atr(h, l, c, n=14):
    tr = [h[0] - l[0]] + [max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1])) for i in range(1, len(c))]
    return ema(tr, n)


def rsi(c, n=14):
    g, ls, out = 0.0, 0.0, [50.0]
    for i in range(1, len(c)):
        d = c[i] - c[i - 1]
        g = (g * (n - 1) + max(d, 0)) / n
        ls = (ls * (n - 1) + max(-d, 0)) / n
        out.append(100 - 100 / (1 + g / ls) if ls else 100)
    return out


# ---------------------------------------------------------------- 5 rule sets
RULES = {
    "R1 Classic breakout": dict(
        piv=5, tol=0.5, min_gap=10, max_gap=80, min_depth=1.5,
        entry="close_break", sl="pattern", sl_buf=0.25, rr=2.5),
    "R2 Neckline retest": dict(
        piv=5, tol=0.5, min_gap=10, max_gap=80, min_depth=1.5,
        entry="retest", retest_wait=12, sl="pattern", sl_buf=0.25, rr=3.0),
    "R3 Trend + EMA200": dict(
        piv=5, tol=0.5, min_gap=10, max_gap=80, min_depth=1.5,
        entry="close_break", sl="pattern", sl_buf=0.25, rr=2.5, trend=True),
    "R4 Tight SL half-pattern": dict(
        piv=5, tol=0.4, min_gap=12, max_gap=80, min_depth=2.0,
        entry="close_break", sl="half", sl_buf=0.1, rr=3.0),
    "R5 RSI divergence": dict(
        piv=5, tol=0.6, min_gap=10, max_gap=100, min_depth=1.5,
        entry="close_break", sl="pattern", sl_buf=0.25, rr=2.5, rsi_div=True),
}


def find_setups(d, r):
    """Yield setups: (detect_index, side, neckline, extreme, half_level)."""
    h, l, c, a, rs = d["h"], d["l"], d["c"], d["atr"], d["rsi"]
    p = r["piv"]
    highs, lows = [], []
    setups = []
    for i in range(2 * p, len(c)):
        j = i - p  # pivot candidate confirmed now
        if h[j] == max(h[j - p:j + p + 1]):
            highs.append(j)
        if l[j] == min(l[j - p:j + p + 1]):
            lows.append(j)
        # double top: last two pivot highs
        if highs and highs[-1] == j and len(highs) >= 2:
            p1, p2 = highs[-2], highs[-1]
            gap = p2 - p1
            if r["min_gap"] <= gap <= r["max_gap"] and abs(h[p1] - h[p2]) <= r["tol"] * a[p2]:
                neck = min(l[p1:p2 + 1])
                top = max(h[p1], h[p2])
                ok = top - neck >= r["min_depth"] * a[p2]
                if r.get("rsi_div"):
                    ok = ok and h[p2] >= h[p1] - 0.2 * a[p2] and rs[p2] < rs[p1] - 3
                if ok:
                    setups.append((i, "short", neck, top, (top + neck) / 2))
        if lows and lows[-1] == j and len(lows) >= 2:
            p1, p2 = lows[-2], lows[-1]
            gap = p2 - p1
            if r["min_gap"] <= gap <= r["max_gap"] and abs(l[p1] - l[p2]) <= r["tol"] * a[p2]:
                neck = max(h[p1:p2 + 1])
                bot = min(l[p1], l[p2])
                ok = neck - bot >= r["min_depth"] * a[p2]
                if r.get("rsi_div"):
                    ok = ok and l[p2] <= l[p1] + 0.2 * a[p2] and rs[p2] > rs[p1] + 3
                if ok:
                    setups.append((i, "long", neck, bot, (bot + neck) / 2))
    return setups


def run(d, r):
    h, l, c, a, e200 = d["h"], d["l"], d["c"], d["atr"], d["ema200"]
    trades, busy_until = [], 0
    for (i0, side, neck, ext, half) in find_setups(d, r):
        if i0 < max(busy_until, 200):
            continue
        sgn = 1 if side == "long" else -1
        # wait up to 24 bars for a close beyond the neckline
        brk = None
        for k in range(i0, min(i0 + r.get("brk_win", 24), len(c))):
            if (sgn == 1 and h[k] > ext + 0 and False):
                break
            # pattern invalid if price makes a new extreme first
            if (sgn == -1 and h[k] > ext) or (sgn == 1 and l[k] < ext):
                break
            if (sgn == -1 and c[k] < neck) or (sgn == 1 and c[k] > neck):
                brk = k
                break
        if brk is None:
            continue
        if r.get("trend"):
            # trade only with the higher trend: shorts below EMA200, longs above
            if (sgn == -1 and c[brk] > e200[brk]) or (sgn == 1 and c[brk] < e200[brk]):
                continue
        ent_i, entry = brk, c[brk]
        if r["entry"] == "retest":
            ent_i = None
            for k in range(brk + 1, min(brk + 1 + r["retest_wait"], len(c))):
                if (sgn == -1 and h[k] >= neck) or (sgn == 1 and l[k] <= neck):
                    ent_i, entry = k, neck
                    break
            if ent_i is None:
                continue
        buf = r["sl_buf"] * a[brk]
        lvl = ext if r["sl"] == "pattern" else half
        sl = lvl - sgn * buf
        risk = (entry - sl) * sgn
        if risk <= 0:
            continue
        tp = entry + sgn * r["rr"] * risk
        # simulate
        start = ent_i + 1 if r["entry"] == "close_break" else ent_i
        res, exit_i = None, None
        for k in range(start, min(start + r.get("max_hold", MAX_HOLD), len(c))):
            hit_sl = (l[k] <= sl) if sgn == 1 else (h[k] >= sl)
            hit_tp = (h[k] >= tp) if sgn == 1 else (l[k] <= tp)
            if r["entry"] == "retest" and k == ent_i:
                hit_tp = False  # conservative on fill bar
            if hit_sl:
                res, exit_i = -1.0, k
                break
            if hit_tp:
                res, exit_i = r["rr"], k
                break
        if res is None:
            exit_i = min(start + r.get("max_hold", MAX_HOLD), len(c)) - 1
            res = (c[exit_i] - entry) * sgn / risk
        res -= 2 * FEE * entry / risk  # fees in R
        trades.append(dict(t=d["t"][ent_i], side=side, entry=entry, sl=sl, tp=tp, r=res))
        busy_until = exit_i + 1
    return trades


def stats(tr):
    if not tr:
        return dict(n=0)
    rs = [t["r"] for t in tr]
    eq, peak, dd = 0, 0, 0
    for x in rs:
        eq += x
        peak = max(peak, eq)
        dd = min(dd, eq - peak)
    wins = [x for x in rs if x > 0]
    gp, gl = sum(wins), -sum(x for x in rs if x <= 0)
    return dict(n=len(rs), win=len(wins) / len(rs) * 100, total=sum(rs), exp=statistics.mean(rs),
                pf=gp / gl if gl else float("inf"), dd=dd)


def load(coin):
    rows = json.load(open(os.path.join(HERE, "data", f"{coin}_1h.json")))
    d = {k: [r[i] for r in rows] for i, k in enumerate("tohlc")}
    d["atr"], d["rsi"], d["ema200"] = atr(d["h"], d["l"], d["c"]), rsi(d["c"]), ema(d["c"], 200)
    return d


def main():
    data = {c: load(c) for c in COINS}
    import datetime as dt
    t0 = dt.datetime.fromtimestamp(data[COINS[0]]["t"][0] / 1000, dt.timezone.utc).date()
    t1 = dt.datetime.fromtimestamp(data[COINS[0]]["t"][-1] / 1000, dt.timezone.utc).date()
    print(f"Period {t0} .. {t1}, H1, coins {COINS}\n")
    hdr = f"{'Rule':26}{'Coin':6}{'Trades':>7}{'Win%':>7}{'TotR':>8}{'Exp R':>7}{'PF':>6}{'MaxDD R':>9}"
    print(hdr); print("-" * len(hdr))
    summary = {}
    for name, r in RULES.items():
        all_tr = []
        for coin in COINS:
            tr = run(data[coin], r); all_tr += tr
            s = stats(tr)
            if s["n"]:
                print(f"{name:26}{coin:6}{s['n']:7}{s['win']:7.1f}{s['total']:8.2f}{s['exp']:7.2f}{s['pf']:6.2f}{s['dd']:9.2f}")
        s = stats(sorted(all_tr, key=lambda t: t["t"]))
        summary[name] = s
        print(f"{name:26}{'ALL':6}{s['n']:7}{s['win']:7.1f}{s['total']:8.2f}{s['exp']:7.2f}{s['pf']:6.2f}{s['dd']:9.2f}")
        print()
    json.dump(summary, open(os.path.join(HERE, "results.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
