#!/usr/bin/env bash
# Builds the Lambda deployment folders that Terraform zips and uploads.
#   - processor: handler + Pillow built for the Lambda runtime (Linux arm64, Python 3.12)
#   - api: handler only (boto3 is already part of the Lambda runtime)
# Run from the repo root, before `terraform plan`.
set -euo pipefail

rm -rf build
mkdir -p build/processor build/api

# The platform flags download Linux arm64 wheels even when building on macOS, Windows or x86
pip install \
  --quiet \
  --target build/processor \
  --platform manylinux_2_28_aarch64 \
  --platform manylinux2014_aarch64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  -r lambda/processor/requirements.txt

cp lambda/processor/handler.py build/processor/
cp lambda/api/handler.py build/api/

echo "Built:"
du -sh build/processor build/api
