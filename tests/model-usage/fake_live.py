import argparse
import json
import os
import signal
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--cliproxy-url")
parser.add_argument("--cliproxy-key-file")
args = parser.parse_args()

def record(event):
    with open(os.environ["MODEL_USAGE_LIVE_MARKER"], "a") as handle:
        handle.write(json.dumps({"event": event, "url": args.cliproxy_url, "pid": os.getpid()}) + "\n")

def stop(*_args):
    record("stop")
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
record("start")
count = 1 if args.cliproxy_url.endswith("new") else 2
print(json.dumps({"schemaVersion": 1, "state": "live", "message": "Live account activity",
                  "providers": [], "accounts": [{"provider": "codex", "accountId": "0123456789abcdef",
                                                   "inFlight": count, "sessions": 3}]}), flush=True)
while True:
    time.sleep(0.1)
    print('{"schemaVersion":1,"heartbeat":true}', flush=True)
