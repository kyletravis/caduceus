#!/bin/sh
set -eu

export PATH="/command:/package/admin/s6/command:$PATH"

# Docker creates new volumes as root. Upstream's setup does not chown these.
mkdir -p /opt/data/installs /opt/data/mnemosyne
chown -R "${HERMES_UID:-1000}:${HERMES_GID:-1000}" /opt/data/installs /opt/data/mnemosyne
/opt/hermes/docker/stage2-hook.sh

# Reuse upstream's HOME, working-directory and privilege-drop handling.
exec /opt/hermes/docker/main-wrapper.sh sh /opt/caduceus/hermes/prepare-integrations.sh
