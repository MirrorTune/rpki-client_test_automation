#!/usr/bin/env bash

set -euo pipefail

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

: "${RPKI_CLIENT_BIN:=/usr/local/sbin/rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${RPKI_TAL_DIR:=/usr/local/etc/rpki}"

: "${ART_DIR:=/work/2_2-2_roa_sig_artifacts}"
: "${WARMUP_DIR:=/work/2_2-2_warmup_output}"
: "${MAIN_LOG:=${ART_DIR}/2_2-2_check_roa_signature_validation.log}"

: "${MAX_ATTEMPTS:=50}"
: "${WARMUP_TIMEOUT:=900}"

mkdir -p "${ART_DIR}" "${WARMUP_DIR}"
: > "${MAIN_LOG}"

exec > >(tee -a "${MAIN_LOG}") 2>&1

info "テスト開始（2.2-2 ROAの暗号化署名検証）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  pass "rpki-client 実行ファイルを確認しました: $(command -v "${RPKI_CLIENT_BIN}")"
else
  fail "rpki-client が見つかりません: RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'"
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ  : ${ART_DIR}"
info "ログファイル        : ${MAIN_LOG}"
info "TALディレクトリ: ${RPKI_TAL_DIR}"

if [ ! -d "${RPKI_TAL_DIR}" ]; then
  fail "TALディレクトリが存在しません: ${RPKI_TAL_DIR}"
fi

mapfile -t TAL_FILES < <(ls -1 "${RPKI_TAL_DIR}"/*.tal 2>/dev/null || true)
if [ "${#TAL_FILES[@]}" -eq 0 ]; then
  fail "TAL が見つかりません: ${RPKI_TAL_DIR}/*.tal"
fi
info "検出したTAL: $(basename -a "${TAL_FILES[@]}" | tr '\n' ' ' | sed 's/ $//')"

count_roa_total() {
  if [ ! -d "${RPKI_CACHE_DIR}" ]; then
    echo 0
    return
  fi
  find "${RPKI_CACHE_DIR}" -type f -name '*.roa' 2>/dev/null | wc -l | tr -d ' '
}

collect_roa_list() {
  local limit="${1:-5000}"
  if [ ! -d "${RPKI_CACHE_DIR}" ]; then
    return
  fi
  find "${RPKI_CACHE_DIR}" -type f -name '*.roa' 2>/dev/null | head -n "${limit}" || true
}

validation_ok() {
  local f="$1"
  grep -Eq 'Validation:[[:space:]]*OK' "$f"
}

looks_cache_missing() {
  local f="$1"
  grep -Eqi 'unable to get local issuer certificate|issuer certificate|not found|no such file|cache' "$f"
}

warmup_online_once() {
  local warmup_log="${ART_DIR}/warmup_online.log"
  info "キャッシュ生成のため rpki-client を実行します（timeout=${WARMUP_TIMEOUT}s）"

  set +e
  "${RPKI_CLIENT_BIN}" -v \
    -d "${RPKI_CACHE_DIR}" \
    $(for t in "${TAL_FILES[@]}"; do printf -- " -t %q" "$t"; done) \
    -s "${WARMUP_TIMEOUT}" \
    "${WARMUP_DIR}" > "${warmup_log}" 2>&1
  rc=$?
  set -e

}

total="$(count_roa_total)"
if [ "${total}" -eq 0 ]; then
  warn "キャッシュ配下に .roa が見つかりませんでした: ${RPKI_CACHE_DIR}"
  warmup_online_once
  total="$(count_roa_total)"
fi

if [ "${total}" -eq 0 ]; then
  fail "キャッシュ配下に .roa が見つかりませんでした: ${RPKI_CACHE_DIR}"
fi

pass "キャッシュ配下の .roa を確認しました（件数=${total} / dir=${RPKI_CACHE_DIR}）"

ROA_LIST="$(collect_roa_list 5000)"
ROA_LIST_COUNT="$(echo "${ROA_LIST}" | sed '/^\s*$/d' | wc -l | tr -d ' ')"
info "検証候補（${MAX_ATTEMPTS}件を試行）: list_count=${ROA_LIST_COUNT}"

warmed=0

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  roa="$(echo "${ROA_LIST}" | sed -n "${i}p" || true)"
  if [ -z "${roa}" ]; then
    fail "検証候補の .roa が不足しています（i=${i} / list_count=${ROA_LIST_COUNT}）"
  fi

  attempt_log="${ART_DIR}/attempt_$(printf '%02d' "${i}").log"

  info "検証対象（ROA）: ${roa}"
  info "rpki-client を -f で検証します"
  info "試行 ${i}/${MAX_ATTEMPTS} ログ: ${attempt_log}"

  set +e
  "${RPKI_CLIENT_BIN}" \
    -d "${RPKI_CACHE_DIR}" \
    $(for t in "${TAL_FILES[@]}"; do printf -- " -t %q" "$t"; done) \
    -f "${roa}" > "${attempt_log}" 2>&1
  rc=$?
  set -e

  if validation_ok "${attempt_log}"; then
    pass "ROA署名検証に成功しました: Validation: OK"
    pass "テスト完了（2.2-2 ROAの暗号化署名検証）"
    exit 0
  fi

  vline="$(grep -E 'Validation:' "${attempt_log}" | head -n 1 || true)"
  if [ -n "${vline}" ]; then
    warn "ROA署名検証に失敗しました: ${vline}"
  else
    warn "ROA署名検証に失敗しました（Validation行なし）"
  fi

  if [ "${warmed}" -eq 0 ] && looks_cache_missing "${attempt_log}"; then
    warmed=1
    warmup_online_once
    ROA_LIST="$(collect_roa_list 5000)"
    ROA_LIST_COUNT="$(echo "${ROA_LIST}" | sed '/^\s*$/d' | wc -l | tr -d ' ')"
    info "検証候補を再取得しました（list_count=${ROA_LIST_COUNT}）"
  fi
done

fail "ROA署名検証の成功を示す 'Validation: OK' が見つかりませんでした。ログを確認してください: ${ART_DIR}"


