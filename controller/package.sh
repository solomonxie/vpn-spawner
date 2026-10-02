#!/bin/bash
# Builds build/scf-controller.zip for the SCF function: controller code + the Tencent SDK parts it uses.
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d)
cp controller/app.py controller/firewall.py controller/bootstrap.sh "$STAGE/"
# Per-product packages instead of the full SDK (~100x smaller); they pin a compatible -common.
venv/bin/pip install -q --target "$STAGE" tencentcloud-sdk-python-cvm tencentcloud-sdk-python-vpc
mkdir -p build
rm -f build/scf-controller.zip
(cd "$STAGE" && zip -qr -X "$OLDPWD/build/scf-controller.zip" . -x '*.pyc' '*__pycache__*')
echo "build/scf-controller.zip $(du -h build/scf-controller.zip | cut -f1)"
