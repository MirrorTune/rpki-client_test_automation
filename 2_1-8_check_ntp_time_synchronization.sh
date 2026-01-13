#!/usr/bin/env bash

set -euo pipefail

: "${EXPECTED_NTP_SERVERS:=ntp.nict.jp}"
: "${MAX_NTP_ABS_OFFSET_SEC:=1.0}"
: "${NTP_TIMEOUT_SEC:=10}"
: "${NTP_LOG_FILE:=/work/2_1-8_ntp_sync.log}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

get_offset_from_ntpdate_output() {
  awk '
    {
      for(i=1;i<=NF;i++){
        if($i=="offset" || $i=="offset,"){
          v=$(i+1)
          gsub(/,/, "", v)
          if(v ~ /^[+-]?[0-9.]+$/){ print v; exit }
        }
      }
    }
  '
}

info "テスト開始（2.1-8 NTPによる時刻同期の確認）"

if command -v ntpdate >/dev/null 2>&1; then
  pass "ntpdate を確認しました"
else
  fail "ntpdate が見つかりません"
fi

if command -v timeout >/dev/null 2>&1; then
  pass "timeout を確認しました"
else
  fail "timeout が見つかりません"
fi

rm -f "${NTP_LOG_FILE}" 2>/dev/null || true

info "同期先: ${EXPECTED_NTP_SERVERS}"
info "許容offset: ${MAX_NTP_ABS_OFFSET_SEC} sec"
info "タイムアウト: ${NTP_TIMEOUT_SEC} sec"
info "ログファイル: ${NTP_LOG_FILE}"

warn "NTPによる時刻同期を実行します"

SELECTED=""
for s in ${EXPECTED_NTP_SERVERS}; do
  set +e
  OUT="$(timeout "${NTP_TIMEOUT_SEC}" ntpdate -q "${s}" 2>&1)"
  RC=$?
  set -e

  printf '%s\n' "===== probe ${s} =====" >> "${NTP_LOG_FILE}"
  printf '%s\n' "${OUT}" >> "${NTP_LOG_FILE}"

  if [ "${RC}" -ne 0 ] || [ -z "${OUT}" ]; then
    continue
  fi

  OFFSET="$(printf '%s\n' "${OUT}" | grep -E 'offset' | get_offset_from_ntpdate_output || true)"
  if [ -n "${OFFSET}" ]; then
    SELECTED="${s}"
    break
  fi
done

if [ -z "${SELECTED}" ]; then
  fail "同期先の選択に失敗しました（詳細: ${NTP_LOG_FILE}）"
fi

info "選択した同期先: ${SELECTED}"

set +e
OUT_SYNC="$(timeout "${NTP_TIMEOUT_SEC}" ntpdate -b "${SELECTED}" 2>&1)"
RC_SYNC=$?
set -e
printf '%s\n' "===== step ${SELECTED} =====" >> "${NTP_LOG_FILE}"
printf '%s\n' "${OUT_SYNC}" >> "${NTP_LOG_FILE}"

if [ "${RC_SYNC}" -ne 0 ]; then
  fail "時刻同期に失敗しました（詳細: ${NTP_LOG_FILE}）"
fi

pass "時刻同期が完了しました"

set +e
OUT_VERIFY="$(timeout "${NTP_TIMEOUT_SEC}" ntpdate -q "${SELECTED}" 2>&1)"
RC_VERIFY=$?
set -e
printf '%s\n' "===== verify ${SELECTED} =====" >> "${NTP_LOG_FILE}"
printf '%s\n' "${OUT_VERIFY}" >> "${NTP_LOG_FILE}"

if [ "${RC_VERIFY}" -ne 0 ]; then
  fail "同期後の確認に失敗しました（詳細: ${NTP_LOG_FILE}）"
fi

OFFSET="$(printf '%s\n' "${OUT_VERIFY}" | grep -E 'offset' | get_offset_from_ntpdate_output || true)"
if [ -z "${OFFSET}" ]; then
  fail "同期後のoffsetの取得に失敗しました（詳細: ${NTP_LOG_FILE}）"
fi

ABS="$(awk -v o="${OFFSET}" 'BEGIN{ if(o<0) o=-o; printf "%.6f", o }')"

info "同期後offset: ${ABS} sec"

if awk -v a="${ABS}" -v t="${MAX_NTP_ABS_OFFSET_SEC}" 'BEGIN{exit !(a <= t)}'; then
  pass "時刻同期が正常に実行できました"
else
  fail "時刻同期が正常に実行できていない可能性があります"
fi

pass "テスト完了（2.1-8 NTPによる時刻同期の確認）"

