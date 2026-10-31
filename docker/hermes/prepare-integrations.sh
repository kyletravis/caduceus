#!/bin/sh
set -eu

. /opt/caduceus/versions.env

python /opt/caduceus/hermes/prepare-mnemosyne.py "$MNEMOSYNE_COMMIT"
python /opt/caduceus/hermes/prepare-iris.py

# Check the selected PM interpreter, not the image's base venv.
python /opt/caduceus/hermes/verify-dependencies.py
echo '[caduceus] Integration dependencies ready'
