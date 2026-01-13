#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[INFO] Docker イメージ rpki-client-test:latest をビルドします..."
docker build -t rpki-client-test:latest "${SCRIPT_DIR}"

echo "[INFO] コンテナ内で 2_1-6_check_artifact_determinism.sh を実行します..."

docker run --rm \
  --entrypoint /bin/bash \
  -e RPKI_CLIENT_BIN="${RPKI_CLIENT_BIN:-/usr/local/sbin/rpki-client}" \
  -e RPKI_CACHE_DIR="${RPKI_CACHE_DIR:-/work/rrdp-cache}" \
  -e RPKI_OUT_DIR="${RPKI_OUT_DIR:-/work/determinism-out}" \
  -e RPKI_LOG_FILE="${RPKI_LOG_FILE:-/work/2_1-6_check_artifact_determinism.log}" \
  -e RPKI_TAL_DIR="${RPKI_TAL_DIR:-/usr/local/etc/rpki}" \
  -e RPKI_VALIDATION_TIME="${RPKI_VALIDATION_TIME:-20260101T000000Z}" \
  -v "${SCRIPT_DIR}:/work" \
  -w /work \
  rpki-client-test:latest \
  2_1-6_check_artifact_determinism.sh

