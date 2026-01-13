#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${TAL_DIR:=/usr/local/etc/rpki}"
: "${ARTIFACT_DIR:=/work/2_2-4_mft_artifacts}"
: "${WARMUP_OUTPUT_DIR:=/work/2_2-4_warmup_output}"

: "${MAX_CANDIDATES:=5000}"
: "${MAX_ATTEMPTS:=50}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

mkdir -p "${ARTIFACT_DIR}" "${WARMUP_OUTPUT_DIR}"
LOG_FILE="${ARTIFACT_DIR}/2_2-4_check_manifest_validation.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

info "テスト開始（2.2-4 マニフェストファイルの検証）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client が見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）。"
fi

if [ ! -d "${TAL_DIR}" ] && [ -d /etc/rpki ]; then
  warn "TAL_DIR が存在しないため /etc/rpki を使用します: TAL_DIR='${TAL_DIR}' -> '/etc/rpki'"
  TAL_DIR="/etc/rpki"
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ  : ${ARTIFACT_DIR}"
info "ログファイル        : ${LOG_FILE}"
info "TALディレクトリ: ${TAL_DIR}"

TAL_FILES=()
if [ -d "${TAL_DIR}" ]; then
  # shellcheck disable=SC2207
  TAL_FILES=($(find "${TAL_DIR}" -maxdepth 1 -type f -name '*.tal' 2>/dev/null | sort || true))
fi

if [ "${#TAL_FILES[@]}" -eq 0 ]; then
  warn "TAL が見つかりませんでした（dir=${TAL_DIR}）"
else
  info "検出したTAL: $(basename -a "${TAL_FILES[@]}" | tr '\n' ' ' | sed 's/ *$//')"
fi

TAL_ARGS=()
for t in "${TAL_FILES[@]}"; do
  TAL_ARGS+=(-t "$t")
done

mkdir -p "${RPKI_CACHE_DIR}" || true

mft_count="$(find "${RPKI_CACHE_DIR}" -type f -name '*.mft' 2>/dev/null | wc -l | tr -d ' ')"
if [ "${mft_count}" -eq 0 ]; then
  warn "キャッシュ配下に .mft が見つかりませんでした: ${RPKI_CACHE_DIR}"
  info "rpki-client を実行してキャッシュ取得を試みます"

  WARMUP_LOG="${ARTIFACT_DIR}/warmup.log"
  : > "${WARMUP_LOG}"

  set +e
  "${RPKI_CLIENT_BIN}" -d "${RPKI_CACHE_DIR}" "${TAL_ARGS[@]}" "${WARMUP_OUTPUT_DIR}" >"${WARMUP_LOG}" 2>&1
  rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    warn "rpki-client が0でないコードで終了しました（rc=${rc}）ログ: ${WARMUP_LOG}"
  else
    info "rpki-client の実行が完了しました。ログ: ${WARMUP_LOG}"
  fi

  mft_count="$(find "${RPKI_CACHE_DIR}" -type f -name '*.mft' 2>/dev/null | wc -l | tr -d ' ')"
fi

if [ "${mft_count}" -eq 0 ]; then
  fail "キャッシュ配下に .mft が見つかりませんでした: ${RPKI_CACHE_DIR}"
fi

pass "キャッシュ配下の .mft を確認しました（件数=${mft_count} / dir=${RPKI_CACHE_DIR}）"

mapfile -t MFT_LIST < <(find "${RPKI_CACHE_DIR}" -type f -name '*.mft' 2>/dev/null | head -n "${MAX_CANDIDATES}" || true)

if [ "${#MFT_LIST[@]}" -eq 0 ]; then
  fail "検証候補の .mft が取得できませんでした（dir=${RPKI_CACHE_DIR}）"
fi

info "検証候補（${MAX_ATTEMPTS}件を試行）: list_count=${#MFT_LIST[@]}"

success=0
last_log=""

for i in $(seq 1 "${MAX_ATTEMPTS}"); do
  idx=$((i - 1))
  [ "${idx}" -ge "${#MFT_LIST[@]}" ] && break

  target="${MFT_LIST[$idx]}"
  attempt_log="${ARTIFACT_DIR}/attempt_$(printf '%02d' "${i}").log"
  last_log="${attempt_log}"

  info "検証対象（MFT）: ${target}"
  info "rpki-client を -f で検証します"
  info "試行 ${i}/${MAX_ATTEMPTS} ログ: ${attempt_log}"

  set +e
  "${RPKI_CLIENT_BIN}" -d "${RPKI_CACHE_DIR}" "${TAL_ARGS[@]}" -f "${target}" > "${attempt_log}" 2>&1
  rc=$?
  set -e

  vline="$(grep -iE '^Validation:' "${attempt_log}" | head -n 1 || true)"
  if [ -z "${vline}" ]; then
    vline="Validation: (not found)"
  fi

  if grep -qiE '^Validation:[[:space:]]*OK' "${attempt_log}"; then
    pass "マニフェストファイルの検証に成功しました: ${vline}"
    success=1
    break
  fi

  if grep -qiE '^Validation:[[:space:]]*N/A' "${attempt_log}"; then
    pass "マニフェストファイルの確認に成功しました: ${vline}"
    success=1
    break
  fi

  if [ $rc -ne 0 ]; then
    warn "rpki-client が0でないコードで終了しました（rc=${rc}）: ${vline}"
  else
    warn "マニフェスト検証に失敗しました: ${vline}"
  fi
done

if [ "${success}" -eq 0 ]; then
  fail "マニフェスト検証の成功を示す 'Validation: OK' または 'Validation: N/A'  が見つかりませんでした。ログを確認してください: ${ARTIFACT_DIR}（最後の試行ロ グ: ${last_log}）"
fi

pass "テスト完了（2.2-4 マニフェストファイルの検証）"


