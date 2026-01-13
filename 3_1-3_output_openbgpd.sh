#!/usr/bin/env bash
set -euo pipefail

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${RPKI_OUT_DIR:=/work/openbgpd-out}"
: "${RPKI_LOG_FILE:=/work/3_1-3_output_openbgpd.log}"
: "${RPKI_OPENBGPD_OUT_FILE:=/work/openbgpd-out/openbgpd}"

info "テスト開始（3.1-3 OpenBGPD形式での出力テスト）"

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
info "OpenBGPD ファイル: ${RPKI_OPENBGPD_OUT_FILE}"

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
rm -f "${RPKI_OPENBGPD_OUT_FILE}" 2>/dev/null || true

info "rpki-client を OpenBGPD 出力指定（-o）で実行します: -o -m -vv -d \"${RPKI_CACHE_DIR}\" \"${RPKI_OUT_DIR}\""

set +e
"${RPKI_CLIENT_BIN}" -o -m -vv \
  -d "${RPKI_CACHE_DIR}" \
  "${RPKI_OUT_DIR}" \
  > /dev/null 2> "${RPKI_LOG_FILE}"
RC=$?
set -e

if [ "${RC}" -ne 0 ]; then
  fail "rpki-client の実行が正常に終了しませんでした（終了コード=${RC}）ログを確認してください: ${RPKI_LOG_FILE}"
fi
pass "rpki-client の実行が正常に完了しました（終了コード0）"

if grep -qi 'not all files processed' "${RPKI_LOG_FILE}"; then
  fail "rpki-client が 'not all files processed' を出力しました。ログ: ${RPKI_LOG_FILE}"
fi

if [ ! -s "${RPKI_OPENBGPD_OUT_FILE}" ]; then
  fail "OpenBGPD ファイルが見つからないか、または空です: ${RPKI_OPENBGPD_OUT_FILE}（ログ: ${RPKI_LOG_FILE}）"
fi
pass "OpenBGPD ファイルを確認しました: ${RPKI_OPENBGPD_OUT_FILE}"

first_line="$(awk 'NF && $1 !~ /^#/ {print; exit}' "${RPKI_OPENBGPD_OUT_FILE}" 2>/dev/null || true)"
last_line="$(awk 'NF && $1 !~ /^#/ {line=$0} END{print line}' "${RPKI_OPENBGPD_OUT_FILE}" 2>/dev/null || true)"

if printf '%s\n' "${first_line}" | grep -Eq '^(roa-set|aspa-set)[[:space:]]*\{$'; then
  pass "OpenBGPD の先頭ブロック開始行を確認しました: ${first_line}"
else
  fail "OpenBGPD の先頭行が想定外です（roa-set { / aspa-set { を期待）: ${first_line}"
fi

if [ "${last_line}" = "}" ]; then
  pass "OpenBGPD の末尾行（ブロック終端）を確認しました: ${last_line}"
else
  fail "OpenBGPD の末尾行が想定外です（'}' を期待）: ${last_line}"
fi

brace_ok="$(
  awk '
    BEGIN{b=0; ok=1}
    {
      line=$0
      sub(/#.*/,"",line)
      for(i=1;i<=length(line);i++){
        c=substr(line,i,1)
        if(c=="{") b++
        else if(c=="}") b--
        if(b<0) ok=0
      }
    }
    END{
      if(b!=0) ok=0
      print ok
    }' "${RPKI_OPENBGPD_OUT_FILE}" 2>/dev/null || echo 0
)"

if [ "${brace_ok}" = "1" ]; then
  pass "ブレース整合性（{ }）を確認しました"
else
  fail "ブレース整合性（{ }）が崩れています"
fi

has_roa_block=0
has_aspa_block=0
if grep -Eq '^[[:space:]]*roa-set[[:space:]]*\{' "${RPKI_OPENBGPD_OUT_FILE}"; then
  has_roa_block=1
fi
if grep -Eq '^[[:space:]]*aspa-set[[:space:]]*\{' "${RPKI_OPENBGPD_OUT_FILE}"; then
  has_aspa_block=1
fi

roa_line_re='^[[:space:]]*([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9A-Fa-f:]+)\/[0-9]{1,3}([[:space:]]+maxlen[[:space:]]+[0-9]{1,3})?[[:space:]]+source-as[[:space:]]+[0-9]+([[:space:]]+expires[[:space:]]+[0-9]+)?[,]?[[:space:]]*$'


if [ "${has_roa_block}" -eq 1 ]; then
  if grep -Eq "${roa_line_re}" "${RPKI_OPENBGPD_OUT_FILE}"; then
    pass "roa-set 内のエントリ行（CIDR/maxlen/source-as）を確認しました"
  else
    fail "roa-set は存在していますが、エントリ行（CIDR maxlen N source-as ASN）が見つかりません"
  fi
elif [ "${has_aspa_block}" -eq 1 ]; then
  if grep -Eq 'provider-as' "${RPKI_OPENBGPD_OUT_FILE}"; then
    pass "aspa-set 内の provider-as を確認しました"
  else
    warn "aspa-set は存在していますが provider-as が見つかりません"
  fi
else
  fail "roa-set / aspa-set 行が見つかりません"
fi

pass "テスト完了（3.1-3 OpenBGPD形式での出力テスト）"

