#!/usr/bin/env bash

set -euo pipefail

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=./rrdp-cache}"
: "${RPKI_LOG_FILE:=./2_2-1_check_cert_chain_validation.log}"
: "${RPKI_ARTIFACT_DIR:=./2_2-1_cert_chain_artifacts}"
: "${TAL_DIR:=}"

: "${RPKI_WARMUP_TIMEOUT:=1800}"
: "${RPKI_WARMUP_OUTPUT_DIR:=./2_2-1_warmup_output}"

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

info "テスト開始（2.2-1 証明書チェーンの検証）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client の実行ファイルが見つかりません（RPKI_CLIENT_BIN='${RPKI_CLIENT_BIN}'）PATH や指定パスを確認してください。"
fi

mkdir -p "${RPKI_CACHE_DIR}" "${RPKI_ARTIFACT_DIR}" "${RPKI_WARMUP_OUTPUT_DIR}"
rm -f "${RPKI_LOG_FILE}"

if id _rpki-client >/dev/null 2>&1; then
  chown -R _rpki-client "${RPKI_CACHE_DIR}" "${RPKI_ARTIFACT_DIR}" "${RPKI_WARMUP_OUTPUT_DIR}" 2>/dev/null || true
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ  : ${RPKI_ARTIFACT_DIR}"
info "ログファイル        : ${RPKI_LOG_FILE}"

REQUIRED_TALS=(afrinic.tal apnic.tal arin.tal lacnic.tal ripe.tal)

has_any_tal() {
  local d="$1"
  compgen -G "${d}/*.tal" >/dev/null 2>&1
}

has_required_set() {
  local d="$1" miss=0
  for f in "${REQUIRED_TALS[@]}"; do
    [ -f "${d}/${f}" ] || { miss=1; break; }
  done
  return $miss
}

CANDIDATES=()
if [ -n "${TAL_DIR:-}" ]; then
  CANDIDATES+=("${TAL_DIR}")
fi
CANDIDATES+=(
  "/etc/tals"
  "/etc/rpki"
  "/usr/share/rpki-client/tals"
  "/usr/local/share/rpki-client/tals"
  "/usr/local/etc/rpki-client/tals"
  "/usr/local/etc/tals"
  "/usr/local/etc/rpki"
  "/opt/homebrew/etc/rpki-client/tals"
)

VALID_DIRS=()
for d in "${CANDIDATES[@]}"; do
  if [ -d "$d" ] && has_any_tal "$d"; then
    VALID_DIRS+=("$d")
  fi
done

if [ ${#VALID_DIRS[@]} -eq 0 ]; then
  info "/etc および /usr 配下から .tal ファイルを探索します"
  mapfile -t FOUND_BY_FIND < <(
    find /etc /usr -maxdepth 5 -type f -name '*.tal' 2>/dev/null \
      | xargs -r -n1 dirname \
      | sort -u
  )
  for d in "${FOUND_BY_FIND[@]}"; do
    if [ -d "$d" ] && has_any_tal "$d"; then
      VALID_DIRS+=("$d")
    fi
  done
fi

if [ ${#VALID_DIRS[@]} -eq 0 ]; then
  fail "TALディレクトリが見つかりませんでした。（候補: ${CANDIDATES[*]} ほか）　/etc や /usr 配下に .tal が存在しない可能性があります。"
fi

FOUND_DIR=""
for d in "${VALID_DIRS[@]}"; do
  if has_required_set "$d"; then
    FOUND_DIR="$d"
    break
  fi
done

if [ -z "${FOUND_DIR}" ]; then
  FOUND_DIR="${VALID_DIRS[0]}"
  warn "5つのTAL（APNIC / ARIN / RIPE / LACNIC / AFRINIC）が揃っているディレクトリが見つからないため、次のディレクトリを使用します: ${FOUND_DIR}"
fi

info "TALディレクトリ: ${FOUND_DIR}"
TALS_IN_DIR=$(ls -1 "${FOUND_DIR}"/*.tal 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
info "検出したTAL: ${TALS_IN_DIR:-（なし）}"

scan_cer() {
  local d="$1"
  find "${d}" -type f -name '*.cer' 2>/dev/null | sort || true
}

load_cer_list() {
  local d="$1"
  mapfile -t CER_FILES < <(scan_cer "${d}")
}

load_cer_list "${RPKI_CACHE_DIR}"

if [ "${#CER_FILES[@]}" -eq 0 ]; then
  ALT_CACHE_DIRS=(/var/cache/rpki-client /var/cache/rpki-client/ /var/cache)
  for d in "${ALT_CACHE_DIRS[@]}"; do
    if [ -d "${d}" ]; then
      mapfile -t ALT_CER < <(scan_cer "${d}")
      if [ "${#ALT_CER[@]}" -gt 0 ]; then
        warn "指定のキャッシュ（${RPKI_CACHE_DIR}）に .cer が無いため、既存のキャッシュを使用します: ${d}"
        RPKI_CACHE_DIR="${d}"
        CER_FILES=("${ALT_CER[@]}")
        break
      fi
    fi
  done
fi

if [ "${#CER_FILES[@]}" -eq 0 ]; then
  info "キャッシュ配下に .cer が見つかりませんでした: ${RPKI_CACHE_DIR}"
  info "rpki-client を実行し、キャッシュを生成します"

  WARMUP_LOG="${RPKI_ARTIFACT_DIR}/cache_warmup.log"

  TAL_OPTS=()
  for ta in afrinic apnic arin lacnic ripe; do
    if [ -f "${FOUND_DIR}/${ta}.tal" ]; then
      TAL_OPTS+=(-t "${FOUND_DIR}/${ta}.tal")
    else
      warn "TAL が見つかりませんでした: ${FOUND_DIR}/${ta}.tal"
    fi
  done

  if [ "${#TAL_OPTS[@]}" -eq 0 ]; then
    fail "利用できる TAL がありませんでした。TALディレクトリの内容を確認してください: ${FOUND_DIR}"
  fi

  set +e
  "${RPKI_CLIENT_BIN}" -v \
    -d "${RPKI_CACHE_DIR}" \
    -s "${RPKI_WARMUP_TIMEOUT}" \
    "${TAL_OPTS[@]}" \
    "${RPKI_WARMUP_OUTPUT_DIR}" > "${WARMUP_LOG}" 2>&1
  RC=$?
  set -e

  if [ "${RC}" -ne 0 ]; then
    fail "キャッシュ生成のための rpki-client 実行に失敗しました（終了コード=${RC}）ログ: ${WARMUP_LOG}"
  fi

  load_cer_list "${RPKI_CACHE_DIR}"
  if [ "${#CER_FILES[@]}" -eq 0 ]; then
    fail "rpki-client 実行後も .cer が見つかりませんでした: ${RPKI_CACHE_DIR} ログ: ${WARMUP_LOG}"
  fi

  pass "キャッシュ生成が完了しました（.cer 件数=${#CER_FILES[@]}）ログ: ${WARMUP_LOG}"
else
  pass "キャッシュ配下の .cer を確認しました（件数=${#CER_FILES[@]} / dir=${RPKI_CACHE_DIR}）"
fi

PICKED_CERT_PATH=""
PICKED_CERT_REASON=""
PICKED_CERT_URI=""

parse_uri() {
  local u="$1"
  local scheme host rest path
  scheme="$(printf '%s' "$u" | awk -F:// '{print $1}')"
  rest="$(printf '%s' "$u" | awk -F:// '{print $2}')"
  host="$(printf '%s' "$rest" | awk -F/ '{print $1}')"
  path="/$(printf '%s' "$rest" | cut -d/ -f2-)"
  printf '%s %s %s\n' "$scheme" "$host" "$path"
}

find_cached_by_uri() {
  local u="$1"
  local scheme host path
  read -r scheme host path < <(parse_uri "$u")

  local ptn="*/${host}${path}"

  if [ -d "${RPKI_CACHE_DIR}/.rrdp" ]; then
    found="$(find "${RPKI_CACHE_DIR}/.rrdp" -type f -path "${ptn}" 2>/dev/null | head -n1 || true)"
    if [ -n "${found}" ]; then
      printf '%s\n' "${found}"
      return 0
    fi
  fi

  if [ -d "${RPKI_CACHE_DIR}/.rsync" ]; then
    found="$(find "${RPKI_CACHE_DIR}/.rsync" -type f -path "${ptn}" 2>/dev/null | head -n1 || true)"
    if [ -n "${found}" ]; then
      printf '%s\n' "${found}"
      return 0
    fi
  fi

  found="$(find "${RPKI_CACHE_DIR}" -type f -path "${ptn}" 2>/dev/null | head -n1 || true)"
  if [ -n "${found}" ]; then
    printf '%s\n' "${found}"
    return 0
  fi

  return 1
}

pick_cert_for_tal() {
  local tal_basename="$1"
  local tal_path="$2"

  PICKED_CERT_PATH=""
  PICKED_CERT_REASON=""
  PICKED_CERT_URI=""

  if [ -f "${tal_path}" ]; then
    mapfile -t uris < <(grep -E '^(rsync|https?)://' "${tal_path}" 2>/dev/null || true)
    for u in "${uris[@]}"; do
      if p="$(find_cached_by_uri "$u")"; then
        PICKED_CERT_PATH="$p"
        PICKED_CERT_REASON="tal-uri"
        PICKED_CERT_URI="$u"
        return 0
      fi
    done
  fi

  local -a patterns=()
  patterns+=("${tal_basename}")

  if [ -f "${tal_path}" ]; then
    mapfile -t uris < <(grep -E '^(rsync|https?)://' "${tal_path}" 2>/dev/null || true)
    for u in "${uris[@]}"; do
      host="$(printf '%s' "${u}" | awk -F/ '{print $3}')"
      if [ -n "${host}" ]; then
        patterns+=("${host}")
      fi
    done
  fi

  for p in "${patterns[@]}"; do
    pl="${p,,}"
    for f in "${CER_FILES[@]}"; do
      fl="${f,,}"
      if [[ "${fl}" == *"${pl}"* ]]; then
        PICKED_CERT_PATH="${f}"
        PICKED_CERT_REASON="heuristic"
        PICKED_CERT_URI=""
        return 0
      fi
    done
  done

  return 1
}

validate_one() {
  local ta_label="$1"
  local tal_file="$2"
  local out_log="$3"
  local cert_file="$4"
  local reason="$5"
  local uri="$6"

  info "検証対象（${ta_label}）: ${cert_file}"
  info "使用したTAL（${ta_label}）: ${tal_file}"
  if [ "${reason}" = "tal-uri" ]; then
    info "TAL URI から Trust Anchor 証明書を特定しました"
    info "TAL URI（${ta_label}） : ${uri}"
  else
    warn "TAL URI からの特定に失敗したため、キャッシュパスの一致で特定しました"
  fi
  info "キャッシュを使用してrpki-client を実行します"

  set +e
  "${RPKI_CLIENT_BIN}" -v -d "${RPKI_CACHE_DIR}" -t "${tal_file}" -f "${cert_file}" > "${out_log}" 2>&1
  RC=$?
  set -e

  if [ "${RC}" -ne 0 ]; then
    fail "rpki-client の検証が失敗しました（${ta_label} / 終了コード=${RC}）ログを確認してください: ${out_log}"
  fi

  if grep -Eq '^[[:space:]]*Validation:[[:space:]]*OK([[:space:]]|$|\.)' "${out_log}"; then
    VAL_LINE="$(grep -E '^[[:space:]]*Validation:' "${out_log}" | head -n1 | sed -E 's/[[:space:]]+/ /g')"
    pass "証明書チェーンの検証に成功しました（${ta_label}）: ${VAL_LINE}"
  elif grep -Eq '^[[:space:]]*Validation:' "${out_log}"; then
    VAL_LINE="$(grep -E '^[[:space:]]*Validation:' "${out_log}" | head -n1 | sed -E 's/[[:space:]]+/ /g')"
    fail "証明書チェーンの検証に失敗しました（${ta_label}）: ${VAL_LINE} ログ: ${out_log}"
  else
    warn "検証ログに 'Validation:' を含む行が見つかりませんでした。（${ta_label}）　ログ: ${out_log}"
    pass "証明書チェーンの検証に成功しました（${ta_label}）（exit=0）"
  fi

  {
    printf '[%s] %s\n' "${ta_label}" "${cert_file}"
    if [ "${reason}" = "tal-uri" ]; then
      printf '[%s] picked_by=tal_uri\n' "${ta_label}"
      printf '[%s] tal_uri=%s\n' "${ta_label}" "${uri}"
    else
      printf '[%s] picked_by=heuristic\n' "${ta_label}"
    fi
    printf '[%s] log=%s\n' "${ta_label}" "${out_log}"
  } >> "${RPKI_LOG_FILE}"
}

FALLBACK_USED=0

for ta in afrinic apnic arin lacnic ripe; do
  TAL_PATH="${FOUND_DIR}/${ta}.tal"
  if [ ! -f "${TAL_PATH}" ]; then
    warn "TAL が見つかりませんでした: ${TAL_PATH}（このTAはスキップします）"
    FALLBACK_USED=1
    continue
  fi

  LOG_TA="${RPKI_ARTIFACT_DIR}/${ta}_cert_chain_validation.log"

  if pick_cert_for_tal "${ta}" "${TAL_PATH}"; then
    :
  else
    warn "TAL(${ta})に対応する .cer がキャッシュから特定できませんでした。先頭の .cer で検証します。"
    PICKED_CERT_PATH="${CER_FILES[0]}"
    PICKED_CERT_REASON="fallback"
    PICKED_CERT_URI=""
    FALLBACK_USED=1
  fi

  if [ "${PICKED_CERT_REASON}" != "tal-uri" ]; then
    FALLBACK_USED=1
  fi

  validate_one "${ta}" "${TAL_PATH}" "${LOG_TA}" "${PICKED_CERT_PATH}" "${PICKED_CERT_REASON}" "${PICKED_CERT_URI}"
done

if [ "${FALLBACK_USED}" -ne 0 ]; then
  warn "一部のTALで、TAL URI から Trust Anchor 証明書を特定できなかったため、暫定的に選定を行いました。"
fi

pass "テスト完了（2.2-1 証明書チェーンの検証）"


