"""Classic chart-pattern breakout backtest on every Hyperliquid perp.

Patterns are detected objectively from swing pivots:
  * a pivot high/low at bar p needs K bars on each side, so it is only KNOWN at
    bar p + K. Detection at bar i only uses pivots with p + K <= i (no look-ahead).
  * trendlines are least-squares lines through the most recent pivot highs / lows;
    slopes are measured in ATR per bar, fit error in ATR.

Patterns:
  ASC_TRIANGLE    flat resistance, rising support
  DESC_TRIANGLE   falling resistance, flat support
  SYM_TRIANGLE    falling resistance, rising support
  RECTANGLE       flat resistance, flat support
  RISING_WEDGE    both lines rising, converging
  FALLING_WEDGE   both lines falling, converging
  BULL_FLAG / BEAR_FLAG   strong pole (>= 4 ATR in 10 bars) then a tight 5-15 bar pause
  DOUBLE_BOTTOM / DOUBLE_TOP   two equal pivots (<= 0.5 ATR apart) and a neckline
  INV_HEAD_SHOULDERS / HEAD_SHOULDERS   head >= 1 ATR beyond two similar shoulders

Entry: first close beyond the boundary (+0.1 ATR), filled at the next open.
Both breakout directions are tested for every pattern. Exits, stop, costs and the
3R-lagging trailing stop are identical to breakout_bt.py.

Usage: python backtest/patterns_bt.py --interval 1d
"""
import argparse
import os

import numpy as np
import pandas as pd

import breakout_bt as bt

K = 3                # pivot strength (bars on each side)
WINDOW = 100         # max pattern length in bars
MIN_SPAN = 15        # min bars between first and last touch
FLAT = 0.03          # |slope| <= FLAT ATR/bar counts as flat
FIT = 0.6            # max distance of a touch from its line, in ATR
MAX_EXT = 30         # breakout must happen within this many bars after the last touch
BUF = 0.1            # close must clear the line by this many ATR

PATTERNS = ["ASC_TRIANGLE", "DESC_TRIANGLE", "SYM_TRIANGLE", "RECTANGLE", "RISING_WEDGE",
            "FALLING_WEDGE", "BULL_FLAG", "BEAR_FLAG", "DOUBLE_BOTTOM", "DOUBLE_TOP",
            "INV_HEAD_SHOULDERS", "HEAD_SHOULDERS"]
# direction the textbook expects (+1 up, -1 down, 0 either)
TEXTBOOK = {"ASC_TRIANGLE": 1, "DESC_TRIANGLE": -1, "SYM_TRIANGLE": 0, "RECTANGLE": 0,
            "RISING_WEDGE": -1, "FALLING_WEDGE": 1, "BULL_FLAG": 1, "BEAR_FLAG": -1,
            "DOUBLE_BOTTOM": 1, "DOUBLE_TOP": -1, "INV_HEAD_SHOULDERS": 1, "HEAD_SHOULDERS": -1}


def pivots(h, l):
    n = len(h)
    ph, pl = [], []
    for p in range(K, n - K):
        win_h = h[p - K:p + K + 1]
        win_l = l[p - K:p + K + 1]
        if h[p] == win_h.max() and (win_h == h[p]).sum() == 1:
            ph.append(p)
        if l[p] == win_l.min() and (win_l == l[p]).sum() == 1:
            pl.append(p)
    return np.array(ph), np.array(pl)


def fit(xs, ys):
    x = np.asarray(xs, float)
    y = np.asarray(ys, float)
    xm, ym = x.mean(), y.mean()
    d = ((x - xm) ** 2).sum()
    b = ((x - xm) * (y - ym)).sum() / d if d > 0 else 0.0
    a = ym - b * xm
    return a, b, np.abs(y - (a + b * x)).max()


def detect(df, f):
    """Return {pattern: (long_signals, short_signals)} boolean arrays."""
    o, h, l, c = df.o.values, df.h.values, df.l.values, df.c.values
    atr = f.atr.values
    n = len(df)
    ph, pl = pivots(h, l)
    out = {p: (np.zeros(n, bool), np.zeros(n, bool)) for p in PATTERNS}
    prev_state = {p: 0 for p in PATTERNS}      # 1 = was already above upper, -1 below lower

    for i in range(WINDOW, n):
        A = atr[i]
        if not np.isfinite(A) or A <= 0:
            continue
        known_h = ph[(ph + K <= i) & (ph >= i - WINDOW)]
        known_l = pl[(pl + K <= i) & (pl >= i - WINDOW)]
        found = {}

        # ---------------- trendline patterns (triangles, rectangle, wedges)
        if len(known_h) >= 2 and len(known_l) >= 2 and len(known_h) + len(known_l) >= 5:
            hx, lx = known_h[-3:], known_l[-3:]
            first, last = min(hx[0], lx[0]), max(hx[-1], lx[-1])
            if last - first >= MIN_SPAN and i - last <= MAX_EXT:
                au, bu, eu = fit(hx, h[hx])
                al, bl, el = fit(lx, l[lx])
                if eu <= FIT * A and el <= FIT * A:
                    su, sl = bu / A, bl / A
                    up_now, lo_now = au + bu * i, al + bl * i
                    w_start = (au + bu * first) - (al + bl * first)
                    w_now = up_now - lo_now
                    if w_now > 0.5 * A:
                        flat_u, flat_l = abs(su) <= FLAT, abs(sl) <= FLAT
                        converging = w_now < w_start
                        name = None
                        if flat_u and sl > FLAT:
                            name = "ASC_TRIANGLE"
                        elif flat_l and su < -FLAT:
                            name = "DESC_TRIANGLE"
                        elif su < -FLAT and sl > FLAT:
                            name = "SYM_TRIANGLE"
                        elif flat_u and flat_l:
                            name = "RECTANGLE"
                        elif su > FLAT and sl > FLAT and converging:
                            name = "RISING_WEDGE"
                        elif su < -FLAT and sl < -FLAT and converging:
                            name = "FALLING_WEDGE"
                        if name:
                            found[name] = (up_now, lo_now)

        # ---------------- double bottom / top (neckline = pivot between the two)
        if len(known_l) >= 2:
            p1, p2 = known_l[-2], known_l[-1]
            mids = known_h[(known_h > p1) & (known_h < p2)]
            if p2 - p1 >= 10 and abs(l[p1] - l[p2]) <= 0.5 * A and len(mids) and i - p2 <= MAX_EXT:
                neck = h[mids].max()
                if neck - min(l[p1], l[p2]) >= 2 * A:
                    found["DOUBLE_BOTTOM"] = (neck, min(l[p1], l[p2]))
        if len(known_h) >= 2:
            p1, p2 = known_h[-2], known_h[-1]
            mids = known_l[(known_l > p1) & (known_l < p2)]
            if p2 - p1 >= 10 and abs(h[p1] - h[p2]) <= 0.5 * A and len(mids) and i - p2 <= MAX_EXT:
                neck = l[mids].min()
                if max(h[p1], h[p2]) - neck >= 2 * A:
                    found["DOUBLE_TOP"] = (max(h[p1], h[p2]), neck)

        # ---------------- head & shoulders (neckline through the two inner pivots)
        if len(known_l) >= 3:
            s1, hd, s2 = known_l[-3:]
            if (l[hd] <= min(l[s1], l[s2]) - A and abs(l[s1] - l[s2]) <= A and s2 - s1 >= 15
                    and i - s2 <= MAX_EXT):
                n1 = known_h[(known_h > s1) & (known_h < hd)]
                n2 = known_h[(known_h > hd) & (known_h < s2)]
                if len(n1) and len(n2):
                    x1, x2 = n1[np.argmax(h[n1])], n2[np.argmax(h[n2])]
                    b = (h[x2] - h[x1]) / (x2 - x1)
                    found["INV_HEAD_SHOULDERS"] = (h[x2] + b * (i - x2), l[hd])
        if len(known_h) >= 3:
            s1, hd, s2 = known_h[-3:]
            if (h[hd] >= max(h[s1], h[s2]) + A and abs(h[s1] - h[s2]) <= A and s2 - s1 >= 15
                    and i - s2 <= MAX_EXT):
                n1 = known_l[(known_l > s1) & (known_l < hd)]
                n2 = known_l[(known_l > hd) & (known_l < s2)]
                if len(n1) and len(n2):
                    x1, x2 = n1[np.argmin(l[n1])], n2[np.argmin(l[n2])]
                    b = (l[x2] - l[x1]) / (x2 - x1)
                    found["HEAD_SHOULDERS"] = (h[hd], l[x2] + b * (i - x2))

        # ---------------- flags: pole of >= 4 ATR in 10 bars, then a tight 5-15 bar pause
        for m in (5, 8, 12, 15):
            s = i - m                      # first bar of the pause
            if s - 10 < 0:
                continue
            pole = c[s - 1] - c[s - 11]
            top, bot = h[s:i].max(), l[s:i].min()
            if pole >= 4 * A and (top - bot) <= 0.5 * pole and top <= h[s - 11:s].max() + 0.25 * A \
                    and c[i - 1] - c[s] <= 0:
                found.setdefault("BULL_FLAG", (top, bot))
            if -pole >= 4 * A and (top - bot) <= 0.5 * -pole and bot >= l[s - 11:s].min() - 0.25 * A \
                    and c[i - 1] - c[s] >= 0:
                found.setdefault("BEAR_FLAG", (top, bot))

        # ---------------- breakout = first close beyond the boundary
        for name in PATTERNS:
            if name in found:
                up, lo = found[name]
                state = 1 if c[i] > up + BUF * A else (-1 if c[i] < lo - BUF * A else 0)
                if state == 1 and prev_state[name] != 1:
                    out[name][0][i] = True
                elif state == -1 and prev_state[name] != -1:
                    out[name][1][i] = True
                prev_state[name] = state
            else:
                prev_state[name] = 0
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", default="1d")
    ap.add_argument("--data", default="backtest/data")
    ap.add_argument("--out", default="backtest/results")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    data = bt.load(a.interval, a.data)
    bpd = bt.BARS_PER_DAY[a.interval]
    rows, trades_all = [], []
    rng = np.random.default_rng(11)
    ctrl = []
    for coin, (df, _) in data.items():
        f = bt.features(df, bpd)
        liquid = ((f["adv"] >= bt.MIN_ADV) & f["atr"].notna() & f["sma200"].notna()).values
        up_trend = (df.c > f.sma200).values
        sig = detect(df, f)
        for name in PATTERNS:
            Lr, Sr = sig[name]
            for trend in (False, True):
                L = Lr & liquid & (up_trend if trend else True)
                S = Sr & liquid & (~up_trend if trend else True)
                for side, arrL, arrS in (("LONG", L, np.zeros_like(L)), ("SHORT", np.zeros_like(S), S)):
                    if not (arrL.any() or arrS.any()):
                        continue
                    for t in bt.simulate(coin, df, f, arrL, arrS, a.interval):
                        t.update(pattern=name, trend=trend)
                        trades_all.append(t)
        # random control with the same exit, ~1 entry per 40 liquid bars per side
        r = rng.random(len(df))
        RL = (r < 0.0125) & liquid
        RS = (r > 1 - 0.0125) & liquid
        for t in bt.simulate(coin, df, f, RL, np.zeros_like(RL), a.interval):
            t.update(pattern="RANDOM", trend=False); ctrl.append(t)
        for t in bt.simulate(coin, df, f, np.zeros_like(RS), RS, a.interval):
            t.update(pattern="RANDOM", trend=False); ctrl.append(t)

    T = pd.DataFrame(trades_all + ctrl)
    T.to_csv(os.path.join(a.out, f"pattern_trades_{a.interval}.csv"), index=False)
    cut = T.entry_time.quantile(0.6)
    for (name, trend, side), g in T.groupby(["pattern", "trend", "side"]):
        s = bt.stats(g)
        oos = bt.stats(g[g.entry_time > cut])
        tb = TEXTBOOK.get(name, 0)
        rows.append({"pattern": name, "filter": "+TREND" if trend else "-", "side": side,
                     "textbook": "yes" if (tb == 1 and side == "LONG") or (tb == -1 and side == "SHORT") else ("either" if tb == 0 and name != "RANDOM" else "no"),
                     **{k: s[k] for k in ["trades", "win_rate_%", "avg_R", "profit_factor", "total_R", "max_dd_R", "reached_3R_%"]},
                     "oos_trades": oos["trades"] if oos else 0, "oos_avg_R": oos["avg_R"] if oos else np.nan,
                     "oos_pf": oos["profit_factor"] if oos else np.nan})
    res = pd.DataFrame(rows).sort_values(["side", "profit_factor"], ascending=[True, False])
    res.to_csv(os.path.join(a.out, f"pattern_summary_{a.interval}.csv"), index=False)
    pd.set_option("display.width", 250)
    print(f"{len(data)} coins, interval {a.interval}, OOS from {cut:%Y-%m-%d}")
    print(res.round(2).to_string(index=False))


if __name__ == "__main__":
    main()
