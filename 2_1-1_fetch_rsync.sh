#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./rsync-cache}"
: "${RPKI_OUT_DIR:=./rsync-out}"
: "${RPKI_LOG_FILE:=./2_1-1_fetch_rsync.log}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1-1 rsyncプロトコルでのデータ取得）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client の実行ファイルが見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）PATH や指定パスを確認してください。"
fi

if command -v rsync >/dev/null 2>&1; then
  RSYNC_BIN="$(command -v rsync)"
  pass "rsync の存在を確認しました: ${RSYNC_BIN}"
elif command -v openrsync >/dev/null 2>&1; then
  RSYNC_BIN="$(command -v openrsync)"
  pass "OpenRsync の存在を確認しました: ${RSYNC_BIN}"
else
  warn "rsync / openrsync が見つかりません。"
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

info "rpki-client を rsync を使用して実行します: -R -j -m -vv -d \"${RPKI_CACHE_DIR}\" \"${RPKI_OUT_DIR}\""

set +e
"${RPKI_CLIENT_BIN}" -R -j -m -vv \
  -d "${RPKI_CACHE_DIR}" \
  "${RPKI_OUT_DIR}" \
  > "${RPKI_LOG_FILE}" 2>&1
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  fail "rpki-client の実行が正常に終了しませんでした（終了コード=${RC}）ログを確認してください: ${RPKI_LOG_FILE}"
fi
pass "rpki-client の実行が正常に完了しました"

if grep -q 'rsync://' "${RPKI_LOG_FILE}"; then
  pass "ログ内で rsync による取得を示す記録を確認しました"

  info "該当ログ:"
  grep -n -m 5 'rsync://' "${RPKI_LOG_FILE}" | while IFS= read -r line; do
    info "${line}"
  done
else
  warn "ログ内で rsync による取得を示す記録を確認できませんでした。"
fi

pass "テスト完了（2.1-1 rsyncプロトコルでのデータ取得）"

