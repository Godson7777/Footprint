"""Re-test all rules and R1+ on ~2 years of gold futures H1 (Yahoo GC=F).

Run: python3 backtest/r1_longdata.py
Note: GC=F is a continuous front-month futures series, so contract rolls can leave small gaps.
"""
import datetime as dt, sys
sys.argv = sys.argv[:1]
import double_top_bottom as m
from r1_optimize import run_ext

d = m.load("GC")
utc = lambda t: dt.datetime.fromtimestamp(t / 1000, dt.timezone.utc)
months = (d["t"][-1] - d["t"][0]) / 1000 / 86400 / 30.4
print(f"GC=F H1 {utc(d['t'][0]).date()} .. {utc(d['t'][-1]).date()} ({len(d['t'])} candles, {months:.1f} months)\n")


def show(name, r):
    tr = run_ext(d, r)
    s = m.stats(tr)
    if not s["n"]:
        print(f"{name:34} n=0"); return
    # split by 6-month blocks to check stability
    blocks = {}
    for t in tr:
        u = utc(t["t"]); key = f"{u.year}{'H1' if u.month <= 6 else 'H2'}"
        blocks.setdefault(key, []).append(t)
    bl = " ".join(f"{k}:{m.stats(v)['pf']:.2f}({len(v)})" for k, v in sorted(blocks.items()))
    print(f"{name:34} n={s['n']:3} /bln={s['n']/months:3.1f} win={s['win']:3.0f}% pf={s['pf']:.2f} "
          f"tot={s['total']:6.2f}R dd={s['dd']:6.2f} | PF per half-year: {bl}")


print("-- 5 original rules --")
for name, r in m.RULES.items():
    show(name, r)
print("\n-- R1+ (session 07-20 UTC) --")
R1P = dict(m.RULES["R1 Classic breakout"], session=(7, 20))
for rr in (2.5, 3.0):
    show(f"R1+ RR{rr}", dict(R1P, rr=rr))
print("\n-- R1+ session sensitivity (RR3) --")
for s in [None, (6, 20), (7, 20), (8, 20), (7, 21), (6, 21), (12, 20), (13, 17)]:
    show(f"session {s}", dict(R1P, rr=3.0, session=s))
print("\n-- R1+ with trend filter / other tweaks (RR3) --")
show("R1+ + EMA200 trend", dict(R1P, rr=3.0, trend=True))
show("R1+ depth 2.0", dict(R1P, rr=3.0, min_depth=2.0))
show("R1+ tol 0.3", dict(R1P, rr=3.0, tol=0.3))
show("R1+ sl_buf 0.5", dict(R1P, rr=3.0, sl_buf=0.5))
show("R1+ piv 7", dict(R1P, rr=3.0, piv=7))
show("R1+ body 0.5", dict(R1P, rr=3.0, body=0.5))
