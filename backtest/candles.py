"""Backtest candlestick patterns on gold H1 (Yahoo GC=F, ~29 months).

Run: python3 backtest/candles.py
Entry: close of the pattern candle. SL: beyond the pattern's extreme + 0.1 x ATR.
TP: RR x risk (2.5 / 3). Time exit 48 candles. Same-candle SL+TP counts as SL. Fees 0.045%/side.
Filters tested per pattern:
- none
- trend: long only above EMA200, short only below
- location: pattern extreme is the lowest low (long) / highest high (short) of the last 20 candles
- trend + location
Stability: profit factor per half-year.
"""
import datetime as dt, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m

d = m.load("GC")
o, h, l, c, a, e, rs, T = d["o"], d["h"], d["l"], d["c"], d["atr"], d["ema200"], d["rsi"], d["t"]
FEE, HOLD, LOOK = 0.00045, 48, 20


def body(i): return abs(c[i] - o[i])
def rng(i): return h[i] - l[i] or 1e-9
def bull(i): return c[i] > o[i]
def bear(i): return c[i] < o[i]
def up_w(i): return h[i] - max(o[i], c[i])
def lo_w(i): return min(o[i], c[i]) - l[i]


# each returns (side, sl_level) or None; sl_level = pattern extreme
def engulfing(i):
    if bear(i - 1) and bull(i) and c[i] >= o[i - 1] and o[i] <= c[i - 1] and body(i) > body(i - 1) and body(i) > 0.5 * a[i]:
        return 1, min(l[i], l[i - 1])
    if bull(i - 1) and bear(i) and c[i] <= o[i - 1] and o[i] >= c[i - 1] and body(i) > body(i - 1) and body(i) > 0.5 * a[i]:
        return -1, max(h[i], h[i - 1])


def pinbar(i):
    if lo_w(i) >= 2 * body(i) and lo_w(i) >= 0.6 * rng(i) and rng(i) > 0.8 * a[i]:
        return 1, l[i]
    if up_w(i) >= 2 * body(i) and up_w(i) >= 0.6 * rng(i) and rng(i) > 0.8 * a[i]:
        return -1, h[i]


def star(i):  # morning / evening star
    if bear(i - 2) and body(i - 2) > 0.6 * a[i] and body(i - 1) < 0.3 * body(i - 2) and bull(i) and c[i] > (o[i - 2] + c[i - 2]) / 2:
        return 1, min(l[i - 2:i + 1])
    if bull(i - 2) and body(i - 2) > 0.6 * a[i] and body(i - 1) < 0.3 * body(i - 2) and bear(i) and c[i] < (o[i - 2] + c[i - 2]) / 2:
        return -1, max(h[i - 2:i + 1])


def inside_break(i):  # inside bar, then close beyond mother bar
    if h[i - 1] < h[i - 2] and l[i - 1] > l[i - 2]:
        if c[i] > h[i - 2]: return 1, l[i - 2]
        if c[i] < l[i - 2]: return -1, h[i - 2]


def tweezer(i):
    tol = 0.1 * a[i]
    if bear(i - 1) and bull(i) and abs(l[i] - l[i - 1]) <= tol:
        return 1, min(l[i], l[i - 1])
    if bull(i - 1) and bear(i) and abs(h[i] - h[i - 1]) <= tol:
        return -1, max(h[i], h[i - 1])


def three_soldiers(i):
    if all(bull(k) and body(k) > 0.5 * a[i] and c[k] > c[k - 1] for k in (i - 2, i - 1, i)):
        return 1, l[i - 2]
    if all(bear(k) and body(k) > 0.5 * a[i] and c[k] < c[k - 1] for k in (i - 2, i - 1, i)):
        return -1, h[i - 2]


def marubozu(i):  # strong momentum candle
    if body(i) > 1.5 * a[i] and body(i) > 0.85 * rng(i):
        return (1, l[i]) if bull(i) else (-1, h[i])


PATTERNS = dict(Engulfing=engulfing, PinBar=pinbar, MorningEveningStar=star, InsideBarBreak=inside_break,
                Tweezer=tweezer, ThreeSoldiersCrows=three_soldiers, Marubozu=marubozu)


def backtest(fn, rr, trend, loc, session=None):
    trades, busy = [], 0
    for i in range(210, len(c) - 1):
        if i < busy: continue
        p = fn(i)
        if not p: continue
        side, ext = p
        if trend and ((side == 1 and c[i] < e[i]) or (side == -1 and c[i] > e[i])): continue
        if loc:
            if side == 1 and ext > min(l[i - LOOK:i + 1]): continue
            if side == -1 and ext < max(h[i - LOOK:i + 1]): continue
        hr = (T[i] // 3600000) % 24
        if session and not (session[0] <= hr < session[1]): continue
        entry = c[i]; sl = ext - side * 0.1 * a[i]; risk = (entry - sl) * side
        if risk < 0.2 * a[i]: continue  # skip tiny stops (fees/noise)
        tp = entry + side * rr * risk; res = None
        for k in range(i + 1, min(i + 1 + HOLD, len(c))):
            if (l[k] <= sl if side == 1 else h[k] >= sl): res = -1.0; break
            if (h[k] >= tp if side == 1 else l[k] <= tp): res = rr; break
        if res is None:
            k = min(i + HOLD, len(c) - 1); res = (c[k] - entry) * side / risk
        res -= 2 * FEE * entry / risk
        trades.append(dict(t=T[i], r=res)); busy = k + 1
    return trades


def halves(tr):
    b = {}
    for t in tr:
        u = dt.datetime.fromtimestamp(t["t"] / 1000, dt.timezone.utc)
        b.setdefault(f"{u.year}{'a' if u.month <= 6 else 'b'}", []).append(t)
    return [m.stats(v)["pf"] for _, v in sorted(b.items())]


months = (T[-1] - T[0]) / 864e5 / 30.4
rows = []
for name, fn in PATTERNS.items():
    for flt in ("none", "trend", "loc", "trend+loc"):
        for rr in (2.5, 3.0):
            tr = backtest(fn, rr, "trend" in flt, "loc" in flt)
            s = m.stats(tr)
            if s["n"] < 20: continue
            hv = halves(tr)
            good = sum(1 for x in hv if x > 1.0)
            rows.append((s["pf"], name, flt, rr, s, hv, good))
rows.sort(key=lambda x: -x[0])
print(f"GC=F H1, {months:.1f} months. Patterns with >=20 trades, sorted by profit factor\n")
print(f"{'Pattern':20}{'Filter':11}{'RR':>4}{'n':>5}{'/bln':>6}{'Win%':>6}{'PF':>6}{'TotR':>8}{'DD':>7}  PF per half-year (good halves)")
for pf, name, flt, rr, s, hv, good in rows:
    print(f"{name:20}{flt:11}{rr:4}{s['n']:5}{s['n']/months:6.1f}{s['win']:6.0f}{s['pf']:6.2f}{s['total']:8.2f}{s['dd']:7.2f}  "
          + " ".join(f"{x:.2f}" for x in hv) + f"  ({good}/{len(hv)})")
