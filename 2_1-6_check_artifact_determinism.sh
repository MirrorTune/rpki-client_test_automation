#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./rrdp-cache}"
: "${RPKI_OUT_DIR:=./determinism-out}"
: "${RPKI_LOG_FILE:=./2_1-6_check_artifact_determinism.log}"
: "${RPKI_TAL_DIR:=/usr/local/etc/rpki}"
: "${RPKI_TAL_FILE:=/usr/local/etc/rpki/ta}"
: "${RPKI_TMP_DIR:=${RPKI_OUT_DIR}/tmp}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1-6 同一条件での成果物一致テスト）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client の実行ファイルが見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）PATH や指定パスを確認してください。"
fi

for c in find sort xargs sha256sum diff tail date; do
  if command -v "${c}" >/dev/null 2>&1; then
    pass "${c} を確認しました"
  else
    fail "${c} が見つかりません"
  fi
done

if [ -d "${RPKI_TAL_DIR}" ]; then
  TAL_COUNT="$(find "${RPKI_TAL_DIR}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${TAL_COUNT}" -gt 0 ]; then
    pass "TALファイルを確認しました（${TAL_COUNT}件）: ${RPKI_TAL_DIR}"
  else
    fail "TALディレクトリは存在しますが、ファイルが見つかりません: ${RPKI_TAL_DIR}"
  fi
else
  fail "TALディレクトリが見つかりません: ${RPKI_TAL_DIR}"
fi

TAL_FILE_SELECTED=""
if [ -f "${RPKI_TAL_FILE}" ]; then
  TAL_FILE_SELECTED="${RPKI_TAL_FILE}"
else
  set +e
  TAL_FILE_SELECTED="$(find "${RPKI_TAL_DIR}" -maxdepth 1 -type f -name '*.tal' 2>/dev/null | sort | head -n 1)"
  set -e
fi

if [ -z "${TAL_FILE_SELECTED}" ]; then
  fail "TALファイルを特定できませんでした"
fi

if [ ! -f "${TAL_FILE_SELECTED}" ]; then
  fail "TALファイルが見つかりません: ${TAL_FILE_SELECTED}"
fi

pass "TALファイルを特定しました: ${TAL_FILE_SELECTED}"

mkdir -p "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}" "${RPKI_TMP_DIR}"
chmod -R a+rwx "${RPKI_OUT_DIR}" 2>/dev/null || true
chmod -R a+rwx "${RPKI_CACHE_DIR}" 2>/dev/null || true
chmod -R a+rwx "${RPKI_TMP_DIR}" 2>/dev/null || true

export TMPDIR="${RPKI_TMP_DIR}"

RUN1_DIR="${RPKI_OUT_DIR}/run1"
RUN2_DIR="${RPKI_OUT_DIR}/run2"
RUN1_LOG="${RPKI_OUT_DIR}/2_1-6_run1.log"
RUN2_LOG="${RPKI_OUT_DIR}/2_1-6_run2.log"
RUN1_MANIFEST="${RPKI_OUT_DIR}/2_1-6_run1.sha256"
RUN2_MANIFEST="${RPKI_OUT_DIR}/2_1-6_run2.sha256"
DIFF_FILE="${RPKI_OUT_DIR}/2_1-6_manifest.diff"

rm -rf "${RUN1_DIR}" "${RUN2_DIR}"
rm -f "${RUN1_LOG}" "${RUN2_LOG}" "${RUN1_MANIFEST}" "${RUN2_MANIFEST}" "${DIFF_FILE}" "${RPKI_LOG_FILE}"

mkdir -p "${RUN1_DIR}" "${RUN2_DIR}"
chmod -R a+rwx "${RUN1_DIR}" "${RUN2_DIR}" 2>/dev/null || true

if id _rpki-client >/dev/null 2>&1; then
  chown -R _rpki-client "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}" 2>/dev/null || true
  chown -R _rpki-client "${RUN1_DIR}" "${RUN2_DIR}" 2>/dev/null || true
  chown -R _rpki-client "${RPKI_TMP_DIR}" 2>/dev/null || true
fi

normalize_eval_time_to_epoch() {
  local t="$1"
  if printf '%s' "${t}" | grep -Eq '^[0-9]+$'; then
    printf '%s' "${t}"
    return 0
  fi
  if printf '%s' "${t}" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$'; then
    local yyyy mm dd HH MM SS
    yyyy="${t:0:4}"
    mm="${t:4:2}"
    dd="${t:6:2}"
    HH="${t:9:2}"
    MM="${t:11:2}"
    SS="${t:13:2}"
    date -u -d "${yyyy}-${mm}-${dd} ${HH}:${MM}:${SS}" +%s
    return 0
  fi
  return 1
}

NOW_EPOCH="$(date -u +%s)"
NOW_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
NOW_LOCAL="$(date '+%Y-%m-%d %H:%M:%S %Z')"

if [ -n "${RPKI_EVAL_TIME:-}" ]; then
  set +e
  EPOCH_TIME="$(normalize_eval_time_to_epoch "${RPKI_EVAL_TIME}")"
  RC=$?
  set -e
  if [ "${RC}" -ne 0 ]; then
    fail "RPKI_EVAL_TIME の形式が不正です: '${RPKI_EVAL_TIME}'"
  fi
  EPOCH_TIME="$(printf '%s' "${EPOCH_TIME}" | tr -d '\r\n' | tr -d ' ')"
  if ! printf '%s' "${EPOCH_TIME}" | grep -Eq '^[0-9]+$'; then
    fail "epoch秒への正規化に失敗しました: '${EPOCH_TIME}'"
  fi
  EVAL_DESC="RPKI_EVAL_TIME=${RPKI_EVAL_TIME}"
else
  EPOCH_TIME="${NOW_EPOCH}"
  EVAL_DESC="NOW"
fi

CACHE_FILE_COUNT="$(find "${RPKI_CACHE_DIR}" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "${CACHE_FILE_COUNT}" -le 0 ]; then
  warn "キャッシュが空の可能性があります: ${RPKI_CACHE_DIR}"
else
  pass "キャッシュを検出しました（${CACHE_FILE_COUNT}ファイル）: ${RPKI_CACHE_DIR}"
fi

info "現在時刻（UTC）       : ${NOW_UTC}"
info "現在時刻（ローカル）  : ${NOW_LOCAL}"
info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ     : ${RPKI_OUT_DIR}"
info "検証時刻（-P）        : ${EPOCH_TIME} (${EVAL_DESC})"
info "ログファイル         : ${RPKI_LOG_FILE}"

run_once() {
  local outdir="$1"
  local logfile="$2"
  local label="$3"

  mkdir -p "${outdir}"
  chmod -R a+rwx "${outdir}" 2>/dev/null || true
  if id _rpki-client >/dev/null 2>&1; then
    chown -R _rpki-client "${outdir}" 2>/dev/null || true
  fi

  info "${label} をオフライン実行します: -n -P ${EPOCH_TIME} -j -m -vv -t \"${TAL_FILE_SELECTED}\" -d \"${RPKI_CACHE_DIR}\" \"${outdir}\""

  set +e
  "${RPKI_CLIENT_BIN}" -n -j -m -vv \
    -P "${EPOCH_TIME}" \
    -t "${TAL_FILE_SELECTED}" \
    -d "${RPKI_CACHE_DIR}" \
    "${outdir}" \
    > "${logfile}" 2>&1
  RC=$?
  set -e

  info "${label} ログ（末尾）:"
  tail -n 30 "${logfile}" | while IFS= read -r line; do
    info "${line}"
  done

  if [ "${RC}" -ne 0 ]; then
    fail "${label} の rpki-client 実行が失敗しました（終了コード=${RC}）: ${logfile}"
  fi

  if [ -f "${outdir}/rpki.ccr" ]; then
    pass "${label} の rpki.ccr を確認しました"
  else
    fail "${label} の rpki.ccr が見つかりません: ${outdir}/rpki.ccr"
  fi

  if [ -f "${outdir}/json" ]; then
    pass "${label} の json を確認しました"
  else
    warn "${label} の json が見つかりません: ${outdir}/json"
  fi

  if [ -f "${outdir}/metrics" ]; then
    pass "${label} の metrics を確認しました"
  else
    warn "${label} の metrics が見つかりません: ${outdir}/metrics"
  fi

  pass "${label} の rpki-client 実行が完了しました: ${logfile}"
}

make_manifest_deterministic() {
  local rundir="$1"
  local manifest="$2"
  if [ ! -d "${rundir}" ]; then
    fail "成果物ディレクトリが見つかりません: ${rundir}"
  fi
  ( cd "${rundir}" && find . -type f ! -name 'json' ! -name 'metrics' -print0 | sort -z | xargs -0 sha256sum ) > "${manifest}"
}

run_once "${RUN1_DIR}" "${RUN1_LOG}" "run1"
run_once "${RUN2_DIR}" "${RUN2_LOG}" "run2"

make_manifest_deterministic "${RUN1_DIR}" "${RUN1_MANIFEST}"
make_manifest_deterministic "${RUN2_DIR}" "${RUN2_MANIFEST}"

pass "成果物のハッシュ一覧を生成しました: ${RUN1_MANIFEST}"
pass "成果物のハッシュ一覧を生成しました: ${RUN2_MANIFEST}"

set +e
diff -u "${RUN1_MANIFEST}" "${RUN2_MANIFEST}" > "${DIFF_FILE}"
DIFF_RC=$?
set -e

if [ "${DIFF_RC}" -eq 0 ]; then
  pass "成果物が一致しました"
  pass "テスト完了（2.1-6 同一条件での成果物一致テスト）"
  exit 0
fi

warn "run1とrun2で成果物に差分がありました: ${DIFF_FILE}"
info "差分（末尾）:"
tail -n 60 "${DIFF_FILE}" | while IFS= read -r line; do
  info "${line}"
done

fail "成果物が一致しませんでした"

