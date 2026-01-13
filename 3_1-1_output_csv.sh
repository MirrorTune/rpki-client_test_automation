#!/usr/bin/env bash
set -euo pipefail

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${RPKI_OUT_DIR:=/work/csv-out}"
: "${RPKI_LOG_FILE:=/work/3_1-1_output_csv.log}"
: "${RPKI_VRP_CSV_FILE:=/work/csv-out/csv}"

info "テスト開始（3.1-1 CSV形式での出力テスト）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client が見つかりません: ${RPKI_CLIENT_BIN}"
fi

mkdir -p "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}"

if id -u _rpki-client >/dev/null 2>&1; then
  chown -R _rpki-client "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}" 2>/dev/null || true
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ     : ${RPKI_OUT_DIR}"
info "ログファイル         : ${RPKI_LOG_FILE}"

cache_hint=0
if find "${RPKI_CACHE_DIR}" -type f -print -quit 2>/dev/null | grep -q .; then
  cache_hint=1
fi
if [ "${cache_hint}" -ne 0 ]; then
  pass "キャッシュを検出しました"
else
  warn "キャッシュが見つかりませんでした"
fi

rm -f "${RPKI_LOG_FILE}" 2>/dev/null || true
rm -f "${RPKI_OUT_DIR}/csv" "${RPKI_OUT_DIR}/vrp.csv" "${RPKI_OUT_DIR}/vrps.csv" 2>/dev/null || true

info "rpki-client を CSV 出力指定（-c）で実行します: -c -m -vv -d \"${RPKI_CACHE_DIR}\" \"${RPKI_OUT_DIR}\""

set +e
"${RPKI_CLIENT_BIN}" -c -m -vv \
  -d "${RPKI_CACHE_DIR}" \
  "${RPKI_OUT_DIR}" \
  > /dev/null 2> "${RPKI_LOG_FILE}"
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  fail "rpki-client の実行が正常に終了しませんでした（終了コード=${RC}）ログ: ${RPKI_LOG_FILE}"
fi
pass "rpki-client の実行が正常に完了しました（終了コード0）"

if grep -qi 'not all files processed' "${RPKI_LOG_FILE}"; then
  fail "rpki-client が 'not all files processed' を出力しました。ログ: ${RPKI_LOG_FILE}"
fi

found=""
for f in "${RPKI_OUT_DIR}/csv" "${RPKI_OUT_DIR}/vrp.csv" "${RPKI_OUT_DIR}/vrps.csv"; do
  if [ -s "${f}" ]; then
    found="${f}"
    break
  fi
done

if [ -z "${found}" ]; then
  found="$(find "${RPKI_OUT_DIR}" -maxdepth 1 -type f -size +0c 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${found}" ]; then
  fail "CSV ファイルが見つかりませんでした（出力ディレクトリ内に内容が空でないファイルがありません）: ${RPKI_OUT_DIR}"
fi

info "検出した CSV ファイル: ${found}"

line1="$(head -n 1 "${found}" 2>/dev/null || true)"
if echo "${line1}" | grep -q ','; then
  pass "CSV 形式の出力を確認しました（先頭行にカンマ区切り）"
else
  fail "検出したファイルが CSV 形式であると判断できません（先頭行がカンマ区切りでない）: ${line1}"
fi

pass "テスト完了（3.1-1 CSV形式での出力テスト）"

