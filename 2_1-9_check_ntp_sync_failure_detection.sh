#!/usr/bin/env bash

set -euo pipefail

: "${EXPECTED_NTP_SERVERS:=ntp.nict.jp}"
: "${NTP_TIMEOUT_SEC:=10}"
: "${NTP_LOG_FILE:=/work/2_1-9_ntp_failure_detection.log}"

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

cleanup() {
  set +e
  iptables -D OUTPUT -p udp --dport 123 -j DROP >/dev/null 2>&1
  set -e
}
trap cleanup EXIT

info "テスト開始（2.1-9 NTP同期失敗の検知確認）"

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

if command -v iptables >/dev/null 2>&1; then
  pass "iptables を確認しました"
else
  fail "iptables が見つかりません"
fi

rm -f "${NTP_LOG_FILE}" 2>/dev/null || true

info "同期先: ${EXPECTED_NTP_SERVERS}"
info "タイムアウト: ${NTP_TIMEOUT_SEC} sec"
info "ログファイル: ${NTP_LOG_FILE}"

SELECTED=""
for s in ${EXPECTED_NTP_SERVERS}; do
  set +e
  OUT_PRE="$(timeout "${NTP_TIMEOUT_SEC}" ntpdate -q "${s}" 2>&1)"
  RC_PRE=$?
  set -e

  printf '%s\n' "===== precheck ${s} =====" >> "${NTP_LOG_FILE}"
  printf '%s\n' "${OUT_PRE}" >> "${NTP_LOG_FILE}"

  if [ "${RC_PRE}" -ne 0 ] || [ -z "${OUT_PRE}" ]; then
    continue
  fi

  OFFSET_PRE="$(printf '%s\n' "${OUT_PRE}" | grep -E 'offset' | get_offset_from_ntpdate_output || true)"
  if [ -n "${OFFSET_PRE}" ]; then
    SELECTED="${s}"
    break
  fi
done

if [ -z "${SELECTED}" ]; then
  fail "事前の疎通確認に失敗しました（詳細: ${NTP_LOG_FILE}）"
fi

info "選択した同期先: ${SELECTED}"
pass "事前の疎通確認に成功しました"

warn "NTP(UDP/123) を遮断します"
iptables -I OUTPUT -p udp --dport 123 -j DROP
pass "遮断に成功しました"

set +e
OUT_BLOCKED="$(timeout "${NTP_TIMEOUT_SEC}" ntpdate -b "${SELECTED}" 2>&1)"
RC_BLOCKED=$?
set -e

printf '%s\n' "===== blocked-step ${SELECTED} =====" >> "${NTP_LOG_FILE}"
printf '%s\n' "${OUT_BLOCKED}" >> "${NTP_LOG_FILE}"
printf '%s\n' "RC=${RC_BLOCKED}" >> "${NTP_LOG_FILE}"

info "遮断時の終了コード: ${RC_BLOCKED}"

if [ "${RC_BLOCKED}" -eq 0 ]; then
  fail "遮断中に時刻同期が成功しました"
fi

FAIL_SIG=0
if printf '%s\n' "${OUT_BLOCKED}" | grep -Eaiq '(no server suitable|tim(e|ed)\s*out|timeout|unable|failed|refused|unreachable|Temporary failure|Name or service not known)'; then
  FAIL_SIG=1
fi

if [ "${RC_BLOCKED}" -eq 124 ]; then
  FAIL_SIG=1
fi

if [ "${FAIL_SIG}" -eq 1 ]; then
  pass "同期失敗を検知できました（終了コードまたはログで判別可能）"
else
  pass "同期失敗を検知できました（終了コードで判別可能）"
fi

pass "テスト完了（2.1-9 NTP同期失敗の検知確認）"

