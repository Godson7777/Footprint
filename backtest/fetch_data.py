"""Download candle history for every Hyperliquid perp (active and delisted).

Usage:  python backtest/fetch_data.py --interval 4h --out backtest/data
Hyperliquid returns at most 5000 candles per request, so 4h covers ~2.3 years
and 1d covers the whole life of the exchange.
"""
import argparse
import json
import os
import time
import urllib.request

API = "https://api.hyperliquid.xyz/info"
MS = {"1h": 3_600_000, "4h": 14_400_000, "1d": 86_400_000}


def post(body):
    req = urllib.request.Request(API, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception:
            time.sleep(2 ** attempt)
    raise RuntimeError("request failed: %s" % body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", default="4h", choices=list(MS))
    ap.add_argument("--out", default="backtest/data")
    a = ap.parse_args()
    out = os.path.join(a.out, a.interval)
    os.makedirs(out, exist_ok=True)

    meta = post({"type": "meta"})
    coins = [(u["name"], bool(u.get("isDelisted"))) for u in meta["universe"]]
    json.dump([{"coin": c, "delisted": d} for c, d in coins], open(os.path.join(a.out, "universe.json"), "w"))
    end = int(time.time() * 1000)
    start = end - 5000 * MS[a.interval]
    for i, (coin, delisted) in enumerate(coins):
        path = os.path.join(out, coin.replace("/", "_") + ".json")
        if os.path.exists(path):
            continue
        rows = post({"type": "candleSnapshot", "req": {"coin": coin, "interval": a.interval,
                                                       "startTime": start, "endTime": end}})
        json.dump(rows, open(path, "w"))
        print(f"[{i + 1}/{len(coins)}] {coin}{' (delisted)' if delisted else ''}: {len(rows)} candles", flush=True)
        time.sleep(0.25)


if __name__ == "__main__":
    main()
