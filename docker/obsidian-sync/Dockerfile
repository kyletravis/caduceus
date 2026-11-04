# Obsidian Headless: the official command-line Obsidian Sync client.
# https://obsidian.md/help/sync/headless
FROM node:22.23.4-bookworm-slim

ARG OBSIDIAN_HEADLESS_VERSION=0.0.14

# better-sqlite3 ships prebuilt Linux binaries; the toolchain is only a
# fallback for architectures without one, and is removed afterwards.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ \
 && npm install -g "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}" \
 && npm cache clean --force \
 && apt-get purge -y python3 make g++ && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

# Login token and per-vault sync state (SQLite) live here, on a named volume.
ENV XDG_CONFIG_HOME=/config \
    HOME=/config \
    OBSIDIAN_VAULT_PATH=/vault

COPY entrypoint.sh /usr/local/bin/obsidian-sync-entrypoint
ENTRYPOINT ["/bin/sh", "/usr/local/bin/obsidian-sync-entrypoint"]
