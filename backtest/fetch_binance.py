"""Download Binance USD-M futures candles (public archive data.binance.vision)
for every coin in the Hyperliquid universe, to get years of lower-timeframe history.

Hyperliquid's own API only serves the last 5000 candles (1h ~ 7 months, 15m ~ 52 days).

Usage: python backtest/fetch_binance.py --interval 15m --start 2023-01 --end 2026-10
Output: backtest/data/bn<interval>/<COIN>.npz with t (ms), o, h, l, c, v (base), qv (quote USD)
"""
import argparse
import io
import json
import os
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor

import numpy as np

URL = "https://data.binance.vision/data/futures/um/monthly/klines/{s}/{iv}/{s}-{iv}-{m}.zip"
K_MAP = {"kPEPE": "1000PEPE", "kSHIB": "1000SHIB", "kBONK": "1000BONK", "kFLOKI": "1000FLOKI",
         "kLUNC": "1000LUNC", "kNEIRO": "1000NEIRO", "kDOGS": "1000DOGS"}


def months(a, b):
    y, m = map(int, a.split("-"))
    y2, m2 = map(int, b.split("-"))
    while (y, m) <= (y2, m2):
        yield f"{y:04d}-{m:02d}"
        m += 1
        if m == 13:
            y, m = y + 1, 1


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.read()
    except Exception:
        return None


def parse(blob):
    z = zipfile.ZipFile(io.BytesIO(blob))
    rows = []
    for line in z.read(z.namelist()[0]).decode().splitlines():
        if not line or not line[0].isdigit():
            continue                      # header row (newer files have one)
        p = line.split(",")
        rows.append((int(p[0]), float(p[1]), float(p[2]), float(p[3]), float(p[4]), float(p[5]), float(p[7])))
    return rows


def fetch_coin(coin, iv, ms, out):
    sym = K_MAP.get(coin, coin) + "USDT"
    path = os.path.join(out, coin + ".npz")
    if os.path.exists(path):
        return coin, "cached"
    rows = []
    for m in ms:
        blob = get(URL.format(s=sym, iv=iv, m=m))
        if blob:
            rows += parse(blob)
    if not rows:
        np.savez_compressed(path, t=np.array([], dtype=np.int64))
        return coin, "not on Binance"
    a = np.array(sorted(set(rows)))
    np.savez_compressed(path, t=a[:, 0].astype(np.int64), o=a[:, 1], h=a[:, 2], l=a[:, 3], c=a[:, 4], v=a[:, 5], qv=a[:, 6])
    return coin, f"{len(a)} candles"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", default="15m")
    ap.add_argument("--start", default="2023-01")
    ap.add_argument("--end", default="2026-10")
    ap.add_argument("--data", default="backtest/data")
    a = ap.parse_args()
    out = os.path.join(a.data, "bn" + a.interval)
    os.makedirs(out, exist_ok=True)
    coins = [u["coin"] for u in json.load(open(os.path.join(a.data, "universe.json"))) if not u["coin"].startswith("@")]
    ms = list(months(a.start, a.end))
    with ThreadPoolExecutor(8) as ex:
        for k, (coin, msg) in enumerate(ex.map(lambda c: fetch_coin(c, a.interval, ms, out), coins)):
            print(f"[{k + 1}/{len(coins)}] {coin}: {msg}", flush=True)


if __name__ == "__main__":
    main()
