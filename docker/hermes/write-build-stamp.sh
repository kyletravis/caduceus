#!/bin/sh
# Docker excludes .git; retain the checkout's identity for Hermes's version API.
set -eu

repo="$1"
ref="$2"
commit="$(git -C "$repo" rev-parse HEAD)"
commit_date="$(git -C "$repo" log -1 --format=%ct HEAD)"
dirty=false
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]; then
    dirty=true
fi

version=unknown
display="git.$(git -C "$repo" rev-parse --short=7 HEAD)"
distance=null
# Setup preserves user-modified checkouts. Never label a different commit with
# the requested release, or use pyproject.toml's placeholder package version.
if printf '%s\n' "$ref" | grep -Eq '^v(0|[1-9][0-9]{0,2})\.[0-9]+\.[0-9]+$' &&
   [ "$(git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null || true)" = "$commit" ]; then
    version="${ref#v}"
    display="$version"
    distance=0
elif [ "$dirty" = true ]; then
    display="$display.dirty"
fi

# Match upstream's install-stamp schema without adding a host Python dependency.
# All interpolated strings are verified versions or Git hexadecimal identities.
# Omit the build timestamp so rerunning setup preserves Docker's build cache.
printf '{"schemaVersion":2,"commit":"%s","commitDate":%s,"dirty":%s,"source":"docker","distribution":"docker","updateMechanism":"external","baseVersion":"%s","displayVersion":"%s","distance":%s,"payload":"bootstrap"}\n' \
    "$commit" "$commit_date" "$dirty" "$version" "$display" "$distance" \
    > "$repo/install-stamp.json"
printf '  Hermes image version: %s (%s)\n' "$display" "$commit"
