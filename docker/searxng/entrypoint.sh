#!/bin/sh
# SearXNG entrypoint for Caduceus.
#
# config/searxng/settings.yml is tracked by git, so it must not hold API keys.
# SearXNG engines can't read keys from the environment, so when BRAVE_API_KEY
# is set this writes a private copy of the settings with the braveapi engine
# added, points SEARXNG_SETTINGS_PATH at it, and hands off to the image's own
# entrypoint. The copy lives only inside the container, never on the host.
set -eu

src=/etc/searxng/settings.yml
out=/tmp/caduceus-searxng/settings.yml

if [ -n "${BRAVE_API_KEY:-}" ]; then
  mkdir -p "${out%/*}"
  chmod 700 "${out%/*}"
  /usr/local/searxng/.venv/bin/python - "$src" "$out" <<'PY'
import os
import sys

import yaml

src, out = sys.argv[1:]
with open(src) as f:
    cfg = yaml.safe_load(f) or {}

# Replace any braveapi entry so the key in .env is the only source of truth.
engines = [e for e in (cfg.get("engines") or []) if e.get("name") != "braveapi"]
engines.insert(0, {
    "name": "braveapi",
    "engine": "braveapi",
    "api_key": os.environ["BRAVE_API_KEY"],
    "inactive": False,
    "disabled": False,
    "timeout": 6.0,
})
cfg["engines"] = engines

fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PY
  export SEARXNG_SETTINGS_PATH="$out"
  echo "caduceus: braveapi engine enabled from BRAVE_API_KEY"
else
  echo "caduceus: BRAVE_API_KEY not set; braveapi engine stays off"
fi

exec /usr/local/searxng/entrypoint.sh "$@"
