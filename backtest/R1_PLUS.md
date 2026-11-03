# R1+ Classic Double Top/Bottom - XAU H1

Data: Hyperliquid xyz:GOLD + PAXG, H1, 2026-04-09 .. 2026-11-03.
Selected by worst-of (in-sample 60% / out-of-sample 40%) profit factor. See r1_robust.txt, r1_session_check.txt.

## Rules
1. Swing pivot = candle high/low that is the extreme of 5 candles left and 5 right.
2. Double top: last two pivot highs 10-80 candles apart, difference <= 0.5 x ATR(14),
   pattern height (top - neckline) >= 1.5 x ATR. Neckline = lowest low between the two tops.
   Double bottom = mirror.
3. Entry: first H1 candle CLOSE beyond the neckline within 24 candles after the 2nd peak is confirmed.
   Cancel if price makes a new extreme beyond the peaks first.
4. NEW filter: only enter if the breakout candle opens between 07:00 and 20:00 UTC (London + New York).
5. SL: beyond the highest top / lowest bottom + 0.25 x ATR.
6. TP: 3R (2.5R also works). Time exit after 96 candles.

## Result (fees included)
| Version | Trades | Win% | PF | Total R | Max DD | PF in-sample | PF out-of-sample |
|---|---|---|---|---|---|---|---|
| R1 original, 1:2.5 | 51 | 49% | 1.46 | +12.5R | -10.6R | 2.67 | 0.81 |
| R1+ (session), 1:2.5 | 30 | 50% | 1.66 | +9.7R | -5.8R | 1.68 | 1.69 |
| R1+ (session), 1:3 | 30 | 50% | 1.73 | +10.7R | -6.4R | 1.67 | 1.84 |
