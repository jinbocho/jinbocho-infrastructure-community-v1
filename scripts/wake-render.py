#!/usr/bin/env python3
"""Wakes up all Jinbocho Render services by polling their health endpoints
until they respond with HTTP 200, mirroring .github/workflows/wake-render.yml
Pure stdlib (urllib), so it also runs unmodified in a-Shell on iOS.
"""
import urllib.request
import time

TIMEOUT = 90
INTERVAL = 5

SERVICES = [
    ("frontend", "https://jinbocho.onrender.com"),
    ("api-gateway", "https://jinbocho-api-gateway-v1.onrender.com/health"),
    ("auth-service", "https://jinbocho-auth-v1.onrender.com/health"),
    ("catalog-service", "https://jinbocho-catalog-v1.onrender.com/health"),
]


def check(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            return resp.status
    except Exception:
        return 0


def wake(name, url):
    elapsed = 0
    print(f"Pinging {name} ({url}) ...")
    while elapsed < TIMEOUT:
        status = check(url)
        if status == 200:
            print(f"✅ {name} is up ({elapsed}s)")
            return True
        print(f"⏳ {name}: HTTP {status} — retrying in {INTERVAL}s ({elapsed}s elapsed)")
        time.sleep(INTERVAL)
        elapsed += INTERVAL
    print(f"❌ {name} did not respond after {TIMEOUT}s")
    return False


def main():
    failed = False
    for name, url in SERVICES:
        if not wake(name, url):
            failed = True
        print()
    if not failed:
        print("☕ Jinbocho is awake! All services responded with HTTP 200.")
        print("👉 https://jinbocho.onrender.com")
    else:
        print("⚠️ One or more services failed to wake up.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
