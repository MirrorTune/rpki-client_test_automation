#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${TAL_DIR:=/usr/local/etc/rpki}"
: "${ARTIFACT_DIR:=/work/2_2-5_invalid_data_artifacts}"
: "${WARMUP_OUTPUT_DIR:=/work/2_2-5_warmup_output}"

: "${MAX_CANDIDATES:=5000}"
: "${MAX_ATTEMPTS:=50}"
: "${PREFERRED_TYPES:=mft,roa,cer}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

mkdir -p "${ARTIFACT_DIR}" "${WARMUP_OUTPUT_DIR}"
LOG_FILE="${ARTIFACT_DIR}/2_2-5_check_reject_invalid_data.log"

exec > >(tee -a "${LOG_FILE}") 2>&1

info "テスト開始（2.2-5 不正なデータの拒否テスト）"

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
  mapfile -t TAL_FILES < <(find "${TAL_DIR}" -maxdepth 1 -type f -name '*.tal' 2>/dev/null | sort || true)
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

IFS=',' read -r -a TYPE_ORDER <<< "${PREFERRED_TYPES}"
info "対象拡張子: ${PREFERRED_TYPES}"

have_any_target=0
for ext in "${TYPE_ORDER[@]}"; do
  first_path="$(find "${RPKI_CACHE_DIR}" -type f -name "*.${ext}" -print -quit 2>/dev/null || true)"
  if [ -n "${first_path}" ]; then
    have_any_target=1
    break
  fi
done

if [ "${have_any_target}" -eq 0 ]; then
  warn "キャッシュ内に対象拡張子（${PREFERRED_TYPES}）が見つかりませんでした: ${RPKI_CACHE_DIR}"
  info "rpki-client を実行してキャッシュ取得を試みます（warmup）"

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
fi

selected=""
selected_ext=""
selected_reason=""
baseline_log=""

for ext in "${TYPE_ORDER[@]}"; do
  # 候補を収集（pipefail対策で || true を付ける）
  mapfile -t LIST < <(find "${RPKI_CACHE_DIR}" -type f -name "*.${ext}" 2>/dev/null | head -n "${MAX_CANDIDATES}" || true)

  if [ "${#LIST[@]}" -eq 0 ]; then
    continue
  fi

  info "候補探索（.${ext}）: count=${#LIST[@]}（${MAX_ATTEMPTS}件を試行）"

  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    idx=$((i - 1))
    [ "${idx}" -ge "${#LIST[@]}" ] && break

    target="${LIST[$idx]}"
    out="${ARTIFACT_DIR}/baseline_attempt_$(printf '%02d' "${i}")_${ext}.log"

    info "正常サンプル探索（.${ext}）: ${target}"
    info "rpki-client を -f で検証します"
    info "試行 ${i}/${MAX_ATTEMPTS} ログ: ${out}"

    set +e
    "${RPKI_CLIENT_BIN}" -d "${RPKI_CACHE_DIR}" "${TAL_ARGS[@]}" -f "${target}" > "${out}" 2>&1
    rc=$?
    set -e

    if grep -qiE '^Validation:[[:space:]]*OK' "${out}"; then
      selected="${target}"
      selected_ext="${ext}"
      selected_reason="baseline-ok"
      baseline_log="${out}"
      break
    fi

    vline="$(grep -iE '^Validation:' "${out}" | head -n 1 || true)"
    [ -z "${vline}" ] && vline="Validation: (not found)"

    if [ $rc -ne 0 ]; then
      warn "正常サンプルとして不適（rc=${rc}）: ${vline}"
    else
      warn "正常サンプルとして不適: ${vline}"
    fi
  done

  [ -n "${selected}" ] && break
done

if [ -z "${selected}" ]; then
  fail "正常サンプル（Validation: OK）が見つかりませんでした。ログを確認してください: ${ARTIFACT_DIR}"
fi

pass "正常サンプルを特定しました: ${selected}（type=.${selected_ext} / ${selected_reason}）"
info "正常サンプルログ: ${baseline_log}"

ORIG_COPY="${ARTIFACT_DIR}/original.${selected_ext}"
BAD_COPY="${ARTIFACT_DIR}/tampered.${selected_ext}"

cp -f "${selected}" "${ORIG_COPY}"
cp -f "${selected}" "${BAD_COPY}"

size="$(stat -c '%s' "${BAD_COPY}" 2>/dev/null || echo 0)"
if [ "${size}" -le 0 ]; then
  fail "不正サンプルの作成に失敗しました（ファイルサイズ取得不可）: ${BAD_COPY}"
fi

offset=$(( size / 2 ))
[ "${offset}" -ge "${size}" ] && offset=$(( size - 1 ))
[ "${offset}" -lt 0 ] && offset=0

cur_hex="$(dd if="${BAD_COPY}" bs=1 skip="${offset}" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
if [ -z "${cur_hex}" ]; then
  fail "改ざん対象バイトが読み込めませんでした（offset=${offset}）: ${BAD_COPY}"
fi

if [ "${cur_hex}" = "00" ]; then
  new_hex="01"
else
  new_hex="00"
fi

printf "\\x${new_hex}" | dd of="${BAD_COPY}" bs=1 seek="${offset}" count=1 conv=notrunc 2>/dev/null

info "不正サンプルを作成しました（1バイト改ざん）"
info "  元ファイル  : ${ORIG_COPY}"
info "  不正ファイル: ${BAD_COPY}"
info "  改ざん位置  : offset=${offset}（size=${size}）"
info "  変更内容    : ${cur_hex} -> ${new_hex}"

BAD_LOG="${ARTIFACT_DIR}/tampered_validation.log"

info "rpki-client を -f で検証します（不正サンプル / キャッシュ利用）"
info "ログ: ${BAD_LOG}"

set +e
"${RPKI_CLIENT_BIN}" -d "${RPKI_CACHE_DIR}" "${TAL_ARGS[@]}" -f "${BAD_COPY}" > "${BAD_LOG}" 2>&1
BAD_RC=$?
set -e

if grep -qiE '^Validation:[[:space:]]*OK' "${BAD_LOG}"; then
  fail "不正サンプルが Validation: OK になりました。不正サンプルを拒否できていません。ログ: ${BAD_LOG}"
fi

vline="$(grep -iE '^Validation:' "${BAD_LOG}" | head -n 1 || true)"
[ -z "${vline}" ] && vline="Validation: (not found)"

if [ "${BAD_RC}" -ne 0 ]; then
  pass "不正サンプルを拒否できました（rpki-client rc=${BAD_RC} / ${vline}）"
else
  pass "不正サンプルを拒否できました（${vline}）"
fi

pass "テスト完了（2.2-5 不正なデータの拒否テスト）"


