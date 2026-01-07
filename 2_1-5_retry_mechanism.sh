#!/usr/bin/env bash

#   RPKI_CLIENT_BIN=/usr/local/sbin/rpki-client \
#   RPKI_CACHE_DIR=/work/retry-cache \
#   RPKI_OUT_DIR=/work/retry-out \
#   RPKI_LOG_FILE=/work/2_1-5_retry_mechanism.log \
#     bash 2_1-5_retry_mechanism.sh

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./retry-cache}"
: "${RPKI_OUT_DIR:=./retry-out}"
: "${RPKI_LOG_FILE:=./2_1-5_retry_mechanism.log}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1-5 リトライメカニズムの動作確認）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client の実行ファイルが見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）PATH や指定パスを確認してください。"
fi

mkdir -p "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}"

OUT_JSON="${RPKI_OUT_DIR}/json"
OUT_METRICS="${RPKI_OUT_DIR}/metrics"

rm -f "${OUT_JSON}" "${OUT_METRICS}" "${RPKI_LOG_FILE}"

if id _rpki-client >/dev/null 2>&1; then
  chown -R _rpki-client "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}" 2>/dev/null || true
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ     : ${RPKI_OUT_DIR}"
info "ログファイル         : ${RPKI_LOG_FILE}"

info "rpki-client を実行します: -j -m -vv -d \"${RPKI_CACHE_DIR}\" \"${RPKI_OUT_DIR}\""

START_TIME="$(date +%s)"

set +e
"${RPKI_CLIENT_BIN}" -j -m -vv -s 600 \
  -d "${RPKI_CACHE_DIR}" \
  "${RPKI_OUT_DIR}" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

END_TIME="$(date +%s)"
DURATION=$(( END_TIME - START_TIME ))
info "実行時間: ${DURATION} 秒"

if [ "${RC}" -ne 0 ]; then
  fail "rpki-client の実行が正常に終了しませんでした（終了コード=${RC}）ログを確認してください: ${RPKI_LOG_FILE}"
fi
pass "rpki-client の実行が正常に完了しました"

if grep -q 'fallback to rsync' "${RPKI_LOG_FILE}" || \
   grep -q 'fallback to cache' "${RPKI_LOG_FILE}"; then
  pass "ログ内で取得失敗後のフォールバック（RRDP→rsync または rsync→cache）を示す記録を確認しました"

  info "該当ログ:"
  grep -niE -m 5 'fallback to (rsync|cache)' "${RPKI_LOG_FILE}" | while IFS= read -r line; do
    info "${line}"
  done
else
  warn "ログ内でフォールバック（RRDP→rsync または rsync→cache）を示す記録を確認できませんでした"
fi

pass "テスト完了（2.1-5 リトライメカニズムの動作確認）"

