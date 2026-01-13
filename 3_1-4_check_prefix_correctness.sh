#!/usr/bin/env bash
set -euo pipefail

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[36m[INFO]\e[0m %s\n' "$*"; }
warn() { printf '\e[33m[WARN]\e[0m %s\n' "$*"; }

: "${RPKI_CLIENT_BIN:=rpki-client}"
: "${RPKI_CACHE_DIR:=/work/rrdp-cache}"
: "${RPKI_OUT_DIR:=/work/csv-out}"
: "${RPKI_LOG_FILE:=/work/3_1-4_check_prefix_correctness.log}"
: "${RPKI_CSV_FILE:=/work/csv-out/csv}"

info "テスト開始（3.1-4 プレフィックス情報の正確性確認）"

if command -v "${RPKI_CLIENT_BIN}" >/dev/null 2>&1; then
  BIN_PATH="$(command -v "${RPKI_CLIENT_BIN}")"
  pass "rpki-client 実行ファイルを確認しました: ${BIN_PATH}"
else
  fail "rpki-client が見つかりません: ${RPKI_CLIENT_BIN}"
fi

if command -v python3 >/dev/null 2>&1; then
  pass "python3 を確認しました"
else
  fail "python3 が見つかりません"
fi

mkdir -p "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}"

if id -u _rpki-client >/dev/null 2>&1; then
  chown -R _rpki-client "${RPKI_CACHE_DIR}" "${RPKI_OUT_DIR}" 2>/dev/null || true
fi

info "キャッシュディレクトリ: ${RPKI_CACHE_DIR}"
info "出力ディレクトリ     : ${RPKI_OUT_DIR}"
info "ログファイル         : ${RPKI_LOG_FILE}"
info "CSV入力ファイル      : ${RPKI_CSV_FILE}"

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

if [ -s "${RPKI_CSV_FILE}" ]; then
  pass "既存の CSV ファイルを検出しました: ${RPKI_CSV_FILE}"
else
  fail "CSV ファイルが見つかりません。3.1-1のスクリプトを実行し、CSV ファイルを生成してください。: ${RPKI_CSV_FILE}"
fi

EXPECTED_1_PREFIX="${EXPECTED_1_PREFIX:-1.1.1.0/24}"
EXPECTED_1_ASN="${EXPECTED_1_ASN:-13335}"
EXPECTED_2_PREFIX="${EXPECTED_2_PREFIX:-8.8.8.0/24}"
EXPECTED_2_ASN="${EXPECTED_2_ASN:-15169}"

info "既知のROA候補1: ${EXPECTED_1_PREFIX} AS${EXPECTED_1_ASN#AS}"
info "既知のROA候補2: ${EXPECTED_2_PREFIX} AS${EXPECTED_2_ASN#AS}"

set +e
python3 - "${RPKI_CSV_FILE}" "${EXPECTED_1_PREFIX}" "${EXPECTED_1_ASN}" "${EXPECTED_2_PREFIX}" "${EXPECTED_2_ASN}" <<'PY'
import sys, csv, re, ipaddress

csv_path=sys.argv[1]
candidates_raw=[
  (sys.argv[2], sys.argv[3]),
  (sys.argv[4], sys.argv[5]),
]

def norm_asn(a):
    a=str(a).strip()
    if a.upper().startswith("AS"):
        a=a[2:]
    return int(a)

candidates=[(p, norm_asn(a)) for p,a in candidates_raw]

def ok_prefix_and_maxlen(prefix, maxlen):
    net=ipaddress.ip_network(prefix, strict=False)
    plen=net.prefixlen
    bits=net.max_prefixlen
    return (0 <= plen <= bits) and (plen <= maxlen <= bits)

def parse_row(row):
    if not row or len(row) < 3:
        return None
    asn_s=(row[0] or "").strip()
    m=re.match(r"^AS(\d+)$", asn_s, re.IGNORECASE)
    if not m:
        return None
    asn=int(m.group(1))
    prefix=(row[1] or "").strip().strip('"')
    maxlen_s=(row[2] or "").strip()
    if not re.fullmatch(r"\d{1,3}", maxlen_s or ""):
        return None
    maxlen=int(maxlen_s)
    return asn, prefix, maxlen

hit=None
with open(csv_path, newline="") as f:
    r=csv.reader(f)
    for row in r:
        t=parse_row(row)
        if not t:
            continue
        asn, prefix, maxlen=t
        for exp_prefix, exp_asn in candidates:
            if prefix == exp_prefix and asn == exp_asn and ok_prefix_and_maxlen(prefix, maxlen):
                hit=(asn, prefix, maxlen)
                break
        if hit:
            break

if not hit:
    print("[PYFAIL] no candidate matched")
    sys.exit(1)

asn, prefix, maxlen=hit
print(f"[PYPASS] syntax OK: {prefix}")
print(f"[PYPASS] range OK : prefixlen<=maxlen : {prefix} maxlen={maxlen}")
print(f"[PYPASS] expected VRP found: {prefix} AS{asn}")
sys.exit(0)
PY
PYC=$?
set -e

if [ "${PYC}" -ne 0 ]; then
  warn "既知の ROA 候補の照合に失敗しました"
  fail "既知の ROA 候補がいずれも条件を満たしませんでした"
fi

pass "テスト完了（3.1-4 プレフィックス情報の正確性確認）"

