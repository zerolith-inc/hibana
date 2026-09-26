"""Fires 300 overlapping requests at `wrangler dev` and fails on any error or
corrupted stack buffer (review C1). Usage: python3 concurrency.py [port]"""
import collections, concurrent.futures as cf, random, sys, time, urllib.error, urllib.request

port = sys.argv[1] if len(sys.argv) > 1 else "8790"
random.seed(1)

def hit(i):
    time.sleep(random.random())
    url = f"http://127.0.0.1:{port}/stack/req{i}x{chr(65 + i % 26)}/{random.randint(0, 27)}/{random.randint(0, 300)}"
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            return r.status, r.read().decode()[:40]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:80]
    except Exception as e:
        return "EXC", str(e)[:80]

with cf.ThreadPoolExecutor(60) as ex:
    results = list(ex.map(hit, range(300)))
counts = collections.Counter(results)
print(counts.most_common(5))
sys.exit(0 if counts == collections.Counter({(200, "ok"): 300}) else 1)
