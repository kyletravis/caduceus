#!/bin/sh
set -eu

uid="${HERMES_UID:-1000}"
gid="${HERMES_GID:-1000}"
vault="${OBSIDIAN_VAULT_PATH:-/vault}"

# Docker creates new volumes as root; sync runs as the vault's owner.
mkdir -p /config
chown -R "$uid:$gid" /config
as_owner() { setpriv --reuid="$uid" --regid="$gid" --clear-groups "$@"; }

# Sync needs a one-time interactive login and vault link (bin/obsidian-sync).
# Wait for that instead of restarting in a loop.
said=""
until as_owner ob sync-status --path "$vault" >/dev/null 2>&1; do
  if [ -z "$said" ]; then
    echo "Obsidian Sync is not set up for $vault yet. Run: bin/obsidian-sync setup"
    said=1
  fi
  sleep 30
done

echo "Syncing $vault continuously."
exec setpriv --reuid="$uid" --regid="$gid" --clear-groups \
  ob sync --path "$vault" --continuous
