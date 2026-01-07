#!/usr/bin/env bash

#   RPKI_CLIENT_BIN=/usr/local/sbin/rpki-client \
#   RPKI_CACHE_DIR=/work/timeout-cache \
#   RPKI_OUT_DIR=/work/timeout-out \
#   RPKI_LOG_FILE=/work/2_1-4_timeout_setting.log \
#   RPKI_TIMEOUT_SEC=60 \
#     bash 2_1-4_timeout_setting.sh

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./timeout-cache}"
: "${RPKI_OUT_DIR:=./timeout-out}"
: "${RPKI_LOG_FILE:=./2_1-4_timeout_setting.log}"
: "${RPKI_TIMEOUT_SEC:=60}"                   # タイムアウト秒数（デフォルト60秒）

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1-4 データ取得のタイムアウト設定テスト）"

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
info "タイムアウト秒数     : ${RPKI_TIMEOUT_SEC} 秒"

info "rpki-client をタイムアウト指定付きで実行します: -s ${RPKI_TIMEOUT_SEC} -j -m -vv -d \"${RPKI_CACHE_DIR}\" \"${RPKI_OUT_DIR}\""

START_TS="$(date +%s)"

set +e
"${RPKI_CLIENT_BIN}" -s "${RPKI_TIMEOUT_SEC}" -j -m -vv \
  -d "${RPKI_CACHE_DIR}" \
  "${RPKI_OUT_DIR}" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
END_TS="$(date +%s)"
set -e

ELAPSED="$(( END_TS - START_TS ))"
UPPER_LIMIT="$(( RPKI_TIMEOUT_SEC * 2 ))"

info "実行時間: ${ELAPSED} 秒（タイムアウト指定: ${RPKI_TIMEOUT_SEC} 秒）"

if [ "${RC}" -ne 0 ]; then
  fail "rpki-client の実行が正常に終了しませんでした（終了コード=${RC}）ログを確認してください: ${RPKI_LOG_FILE}"
fi
pass "rpki-client の実行が正常に完了しました"

if grep -qi 'timeout' "${RPKI_LOG_FILE}"; then
  pass "ログ内でタイムアウトを示す記録を確認しました"

  info "該当ログ:"
  grep -ni -m 5 'timeout' "${RPKI_LOG_FILE}" | while IFS= read -r line; do
    info "${line}"
  done
else
  warn "ログ内でタイムアウトを示す記録を確認できませんでした"
fi

pass "テスト完了（2.1-4 データ取得のタイムアウト設定テスト）"

