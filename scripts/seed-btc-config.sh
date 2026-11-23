#!/bin/sh
# Container-side helper that seeds Electrum /data/config with auto_connect=false.
# Runs strictly inside a rootless Podman user namespace.

set -eu

# Abort immediately if running in the host root user namespace.
if [ ! -r /proc/self/uid_map ]; then
	echo "[X] Cannot read /proc/self/uid_map; aborting." >&2
	exit 1
fi

if awk '$1 == 0 && $2 == 0 && $3 == 4294967295 { found = 1 } END { exit(found ? 0 : 1) }' /proc/self/uid_map; then
	echo "[X] Detected host root user namespace in /proc/self/uid_map; refusing to run rootful." >&2
	exit 1
fi

python3 - <<'PY'
import json
import os
import pwd

cfg_path = "/data/config"
tmp_path = "/data/config.tmp"
data = {}

if os.path.exists(cfg_path):
    with open(cfg_path, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
    if raw:
        loaded = json.loads(raw)
        if not isinstance(loaded, dict):
            raise SystemExit("[X] Existing /data/config is not a JSON object.")
        data = loaded

data["auto_connect"] = False

with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")

os.chmod(tmp_path, 0o600)
try:
    pw = pwd.getpwnam("electrum")
    os.chown(tmp_path, pw.pw_uid, pw.pw_gid)
except KeyError:
    pass

os.replace(tmp_path, cfg_path)
print("[OK] Seeded /data/config with auto_connect=false.")
PY
