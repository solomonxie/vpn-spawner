#!/bin/bash
# Builds the controller zip for both Tencent SCF (build/scf-controller.zip) and AWS Lambda
# (build/controller.zip, same content; boto3 is built into Lambda): code + the Tencent SDK parts it uses.
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d)
cp controller/app.py controller/aws_backend.py controller/firewall.py controller/bootstrap.sh "$STAGE/"
# Per-product packages instead of the full SDK (~100x smaller); they pin a compatible -common.
venv/bin/pip install -q --target "$STAGE" tencentcloud-sdk-python-cvm tencentcloud-sdk-python-vpc
mkdir -p build
rm -f build/scf-controller.zip
(cd "$STAGE" && zip -qr -X "$OLDPWD/build/scf-controller.zip" . -x '*.pyc' '*__pycache__*')
cp build/scf-controller.zip build/controller.zip
echo "build/scf-controller.zip build/controller.zip $(du -h build/controller.zip | cut -f1)"
