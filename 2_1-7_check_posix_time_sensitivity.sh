#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./rrdp-cache}"
: "${RPKI_OUT_DIR:=./time-sensitivity-out}"
: "${RPKI_LOG_FILE:=./2_1-7_check_posix_time_sensitivity.log}"
: "${TAL_DIR:=/usr/local/etc/rpki}"
: "${TIME_SHIFT_SEC:=43200}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.1-7 同一キャッシュでの検証時刻差テスト）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client の実行ファイルが見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）PATH や指定パスを確認してください。"
fi

for c in find sort xargs sha256sum diff tail date grep awk; do
  if command -v "${c}" >/dev/null 2>&1; then
    pass "${c} を確認しました"
  else
    fail "${c} が見つかりません"
  fi
done

if [ -d "${TAL_DIR}" ]; then
  TAL_FILES="$(find "${TAL_DIR}" -maxdepth 1 -type f -name '*.tal' | sort || true)"
  TAL_COUNT="$(printf '%s\n' "${TAL_FILES}" | grep -c . || true)"
  if [ "${TAL_COUNT}" -gt 0 ]; then
    pass "TALファイルを確認しました（${TAL_COUNT}件）: ${TAL_DIR}"
  else
    fail "TALファイル（*.tal）が見つかりません: ${TAL_DIR}"
  fi
else
  fail "TALディレクトリが見つかりません: ${TAL_DIR}"
fi

if [ -d "${RPKI_CACHE_DIR}" ]; then
  CACHE_FILES="$(find "${RPKI_CACHE_DIR}" -type f 2>/dev/null | wc -l | awk '{print $1}')"
  if [ "${CACHE_FILES}" -gt 0 ]; then
    pass "キャッシュを検出しました（${CACHE_FILES}ファイル）: ${RPKI_CACHE_DIR}"
  else
    fail "キャッシュディレクトリは存在しますが空です: ${RPKI_CACHE_DIR}"
  fi
else
  fail "キャッシュディレクトリが見つかりません: ${RPKI_CACHE_DIR}"
fi

mkdir -p "${RPKI_OUT_DIR}"
rm -f "${RPKI_LOG_FILE}" 2>/dev/null || true

T1_EPOCH="$(date -u +%s)"
T2_EPOCH="$((T1_EPOCH - TIME_SHIFT_SEC))"
T1_ISO="$(date -u -d "@${T1_EPOCH}" +%Y%m%dT%H%M%SZ)"
T2_ISO="$(date -u -d "@${T2_EPOCH}" +%Y%m%dT%H%M%SZ)"

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ     : ${RPKI_OUT_DIR}"
info "TALディレクトリ       : ${TAL_DIR}"
info "検証時刻 t1（-P）     : ${T1_EPOCH} (${T1_ISO})"
info "検証時刻 t2（-P）     : ${T2_EPOCH} (${T2_ISO})"
info "ログファイル         : ${RPKI_LOG_FILE}"

TAL_ARGS=()
while IFS= read -r f; do
  [ -n "${f}" ] || continue
  TAL_ARGS+=(-t "${f}")
done < <(printf '%s\n' "${TAL_FILES}")

ensure_writable_for_rpki_user() {
  local p="$1"
  if id _rpki-client >/dev/null 2>&1; then
    chown -R _rpki-client "${p}" 2>/dev/null || true
  fi
}

run_one() {
  local label="$1"
  local epoch="$2"
  local outdir="$3"
  local logfile="$4"

  rm -rf "${outdir}" 2>/dev/null || true
  mkdir -p "${outdir}"

  ensure_writable_for_rpki_user "${RPKI_CACHE_DIR}"
  ensure_writable_for_rpki_user "${RPKI_OUT_DIR}"
  ensure_writable_for_rpki_user "${outdir}"

  info "${label} をオフラインモードで実行します: -n -P ${epoch} -j -m -vv (TAL指定あり) -d \"${RPKI_CACHE_DIR}\" \"${outdir}\""

  set +e
  TMPDIR="${outdir}" \
  "${RPKI_CLIENT_BIN}" -n -P "${epoch}" -j -m -vv \
    "${TAL_ARGS[@]}" \
    -d "${RPKI_CACHE_DIR}" \
    "${outdir}" \
    > "${logfile}" 2>&1
  local rc=$?
  set -e

  info "${label} ログ（末尾）:"
  tail -n 30 "${logfile}" | while IFS= read -r line; do
    info "${line}"
  done

  if [ "${rc}" -ne 0 ]; then
    fail "${label} の rpki-client 実行が失敗しました（終了コード=${rc}）: ${logfile}"
  fi

  pass "${label} の rpki-client 実行が完了しました: ${logfile}"

  if [ -f "${outdir}/rpki.ccr" ]; then
    pass "${label} の rpki.ccr を確認しました"
  else
    fail "${label} の rpki.ccr が見つかりません: ${outdir}/rpki.ccr"
  fi
}

extract_vrp_entries() {
  local logfile="$1"
  local v
  v="$(grep -E 'VRP Entries:' "${logfile}" | tail -n 1 | awk '{print $3}' || true)"
  if [ -n "${v}" ] && printf '%s' "${v}" | grep -Eq '^[0-9]+$'; then
    printf '%s' "${v}"
  else
    printf '0'
  fi
}

extract_roa_hash() {
  local logfile="$1"
  local h
  h="$(grep -E 'CCR ROA payloads hash:' "${logfile}" | tail -n 1 | awk '{print $5}' || true)"
  printf '%s' "${h}"
}

hash_ccr() {
  local f="$1"
  sha256sum "${f}" | awk '{print $1}'
}

T1_LOG="${RPKI_OUT_DIR}/2_1-7_t1.log"
T2_LOG="${RPKI_OUT_DIR}/2_1-7_t2.log"

run_one "t1" "${T1_EPOCH}" "${RPKI_OUT_DIR}/t1" "${T1_LOG}"
run_one "t2" "${T2_EPOCH}" "${RPKI_OUT_DIR}/t2" "${T2_LOG}"

VRP1="$(extract_vrp_entries "${T1_LOG}")"
VRP2="$(extract_vrp_entries "${T2_LOG}")"
H1="$(extract_roa_hash "${T1_LOG}")"
H2="$(extract_roa_hash "${T2_LOG}")"
CCR1="$(hash_ccr "${RPKI_OUT_DIR}/t1/rpki.ccr")"
CCR2="$(hash_ccr "${RPKI_OUT_DIR}/t2/rpki.ccr")"

info "VRP Entries t1: ${VRP1}"
info "VRP Entries t2: ${VRP2}"
info "CCR ROA payloads hash t1: ${H1}"
info "CCR ROA payloads hash t2: ${H2}"
info "rpki.ccr sha256 t1: ${CCR1}"
info "rpki.ccr sha256 t2: ${CCR2}"

if [ "${VRP1}" -ne "${VRP2}" ]; then
  pass "VRP Entries が変化しました（t1=${VRP1}, t2=${VRP2}）"
  pass "テスト完了（2.1-7 同一キャッシュでの検証時刻差テスト）"
  exit 0
fi

if [ -n "${H1}" ] && [ -n "${H2}" ] && [ "${H1}" != "${H2}" ]; then
  pass "CCR ROA payloads hash が変化しました（t1=${H1}, t2=${H2}）"
  pass "テスト完了（2.1-7 同一キャッシュでの検証時刻差テスト）"
  exit 0
fi

if [ "${CCR1}" != "${CCR2}" ]; then
  pass "rpki.ccr のハッシュが変化しました（t1=${CCR1}, t2=${CCR2}）"
  pass "テスト完了（2.1-7 同一キャッシュでの検証時刻差テスト）"
  exit 0
fi

fail "検証時刻をずらしても差分を検出できませんでした。VRP Entries / ROA hash / rpki.ccr hash がすべて同一です。"

