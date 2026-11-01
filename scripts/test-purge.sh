#!/usr/bin/env bash
# action.yml 的 purge 行為測試（全站清除 + 選擇性 urls/prefixes/patterns）：
# 起一個本機假 FurCDN API，實際執行 action.yml 內 id=run 的 inline 區塊。
# 需要：bash、curl、jq、python3。用法：bash scripts/test-purge.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK="$(mktemp -d)"
PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
SERVER_ROOT="${WORK}/server"
INLINE="${WORK}/inline-run.sh"
OUT="${WORK}/github_output"
LOG="${WORK}/purge.log"
mkdir -p "${SERVER_ROOT}"

PASS=0
FAIL=0

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null
    wait "${SERVER_PID}" 2>/dev/null
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  ok   - $1"
}

bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL - $1"
  [[ -f "${LOG}" ]] && sed 's/^/         /' "${LOG}"
}

assert_contains() {
  if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (找不到 '$2' 於 $1)"; fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then bad "$3 (不該出現 '$2')"; else ok "$3"; fi
}

assert_equals() {
  if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (期望 '$2'，實際 '$1')"; fi
}

# ── 假 API server ───────────────────────────────────────────
cat >"${SERVER_ROOT}/server.py" <<'PY'
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _record(self, body):
        record = {
            "method": self.command,
            "path": self.path,
            "headers": {k.lower(): v for k, v in self.headers.items()},
            "bodyLen": len(body),
        }
        with open(os.path.join(ROOT, "request.json"), "w", encoding="utf-8") as fh:
            json.dump(record, fh)
        with open(os.path.join(ROOT, "body.bin"), "wb") as fh:
            fh.write(body)

    def _respond(self):
        with open(os.path.join(ROOT, "response.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
        if "rawBody" in cfg:
            payload = cfg["rawBody"].encode()
        else:
            payload = json.dumps(cfg["body"], separators=(",", ":")).encode()
        self.send_response(cfg["status"])
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self._record(self.rfile.read(length))
        self._respond()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

python3 "${SERVER_ROOT}/server.py" "${PORT}" "${SERVER_ROOT}" &
SERVER_PID=$!

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

BASE="http://127.0.0.1:${PORT}"

# ── 取出 action.yml 內 id=run 的 inline 區塊 ────────────────
python3 - "${ROOT}/action.yml" "${INLINE}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)

for step in data["runs"]["steps"]:
    if step.get("id") == "run":
        with open(sys.argv[2], "w", encoding="utf-8") as out:
            out.write(step["run"])
        break
else:
    raise SystemExit("action.yml 缺少 id=run 的 step")
PY

# ── 輔助函式 ────────────────────────────────────────────────
set_response() {
  cat >"${SERVER_ROOT}/response.json"
}

reset_request() {
  rm -f "${SERVER_ROOT}/request.json" "${SERVER_ROOT}/body.bin"
}

run_purge() {
  : >"${OUT}"
  env \
    FURCDN_ACTION="purge" \
    FURCDN_API_KEY="fck_test_key" \
    FURCDN_DOMAIN_ID="123" \
    FURCDN_BASE_URL="${BASE}" \
    FURCDN_PURGE_URLS="${URLS-}" \
    FURCDN_PURGE_PREFIXES="${PREFIXES-}" \
    FURCDN_PURGE_PATTERNS="${PATTERNS-}" \
    FURCDN_CERT="" \
    FURCDN_KEY="" \
    GITHUB_OUTPUT="${OUT}" \
    bash "${INLINE}" >"${LOG}" 2>&1
  return $?
}

output_value() {
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2) }' "${OUT}"
}

request_field() {
  jq -r "$1" "${SERVER_ROOT}/request.json"
}

# ── 1. 無輸入：全站清除，不帶 body（既有行為） ─────────────
echo "1. 無 urls/prefixes/patterns：全站清除、不帶 body"
reset_request
set_response <<'JSON'
{"status":200,"body":{"ok":true,"mode":"all","total":5,"success":5}}
JSON
URLS="" PREFIXES="" PATTERNS=""
if run_purge; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(request_field '.path')" "/api/v1/domains/123/purge" "endpoint 不變"
assert_equals "$(request_field '.method')" "POST" "method 為 POST"
assert_equals "$(request_field '.bodyLen')" "0" "不帶 request body"
assert_equals "$(request_field '.headers["content-type"] // ""')" "" "不送 Content-Type"
assert_equals "$(output_value mode)" "all" "output mode"
assert_equals "$(output_value removed)" "" "全站清除時 removed 為空"
assert_contains "${OUT}" '"mode":"all"' "result output 為原始 JSON"
assert_contains "${LOG}" "清除模式：all" "log 印出 mode"
assert_contains "${LOG}" "成功 5/5" "log 印出 success/total"

# ── 2. urls：精確 URL 清除 ─────────────────────────────────
echo "2. urls：只送 urls 陣列"
reset_request
set_response <<'JSON'
{"status":200,"body":{"ok":true,"mode":"selective","total":5,"success":5,"removed":12}}
JSON
URLS=$'https://example.com/a.css?v=1\n/b.js' PREFIXES="" PATTERNS=""
if run_purge; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(request_field '.headers["content-type"]')" "application/json" "Content-Type 為 JSON"
assert_equals "$(cat "${SERVER_ROOT}/body.bin")" \
  '{"urls":["https://example.com/a.css?v=1","/b.js"]}' \
  "body 只有 urls"
assert_equals "$(output_value mode)" "selective" "output mode"
assert_equals "$(output_value removed)" "12" "output removed"
assert_contains "${LOG}" "已清除 12 筆快取項目" "log 印出 removed"

# ── 3. prefixes ────────────────────────────────────────────
echo "3. prefixes：只送 prefixes 陣列"
reset_request
URLS="" PREFIXES=$'/static/\nhttps://example.com/img/' PATTERNS=""
if run_purge; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(cat "${SERVER_ROOT}/body.bin")" \
  '{"prefixes":["/static/","https://example.com/img/"]}' \
  "body 只有 prefixes"

# ── 4. patterns ────────────────────────────────────────────
echo "4. patterns：只送 patterns 陣列"
reset_request
URLS="" PREFIXES="" PATTERNS='/assets/*.js'
if run_purge; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(cat "${SERVER_ROOT}/body.bin")" '{"patterns":["/assets/*.js"]}' "body 只有 patterns"

# ── 5. 三者合併 + 空白行/前後空白忽略 ─────────────────────
echo "5. 三者合併，空白行與前後空白忽略"
reset_request
URLS=$'\n  /index.html  \n\n\t/a.css\t\n' PREFIXES=$'  /static/  \n' PATTERNS=$'\n/img/*\n'
if run_purge; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(cat "${SERVER_ROOT}/body.bin")" \
  '{"urls":["/index.html","/a.css"],"prefixes":["/static/"],"patterns":["/img/*"]}' \
  "body 含三種條件且已去空白"

# ── 6. 剛好 100 筆仍可送出 ────────────────────────────────
echo "6. 總筆數剛好 100：可以送出"
reset_request
URLS="$(for i in $(seq 1 100); do echo "https://example.com/f${i}.js"; done)"
PREFIXES="" PATTERNS=""
if run_purge; then ok "100 筆時 exit code 0"; else bad "100 筆時 exit code 0"; fi
assert_equals "$(jq '.urls | length' "${SERVER_ROOT}/body.bin")" "100" "body 含 100 筆 urls"

# ── 7. 超過 100 筆：本機就失敗，不發請求 ──────────────────
echo "7. 總筆數 101：本機失敗且不呼叫 API"
reset_request
URLS="$(for i in $(seq 1 50); do echo "/f${i}.js"; done)"
PREFIXES="$(for i in $(seq 1 30); do echo "/p${i}/"; done)"
PATTERNS="$(for i in $(seq 1 21); do echo "/g${i}/*"; done)"
if run_purge; then bad "101 筆應失敗"; else ok "101 筆時 exit code 非 0"; fi
assert_contains "${LOG}" "::error::" "輸出 ::error::"
assert_contains "${LOG}" "100" "錯誤訊息提到上限 100"
if [[ -f "${SERVER_ROOT}/request.json" ]]; then bad "超過上限不應呼叫 API"; else ok "超過上限不呼叫 API"; fi

# ── 8. 單筆超過 2048 字元：本機失敗，不發請求 ─────────────
echo "8. 單筆超過 2048 字元：本機失敗且不呼叫 API"
reset_request
URLS="/$(printf 'a%.0s' $(seq 1 2049))" PREFIXES="" PATTERNS=""
if run_purge; then bad "超長項目應失敗"; else ok "超長項目時 exit code 非 0"; fi
assert_contains "${LOG}" "::error::" "輸出 ::error::"
assert_contains "${LOG}" "2048" "錯誤訊息提到 2048"
if [[ -f "${SERVER_ROOT}/request.json" ]]; then bad "超長項目不應呼叫 API"; else ok "超長項目不呼叫 API"; fi

# ── 9. 非 JSON 回應不崩潰 ────────────────────────────────
echo "9. 非 JSON 回應（例如反向代理頁面）"
reset_request
set_response <<'JSON'
{"status":200,"rawBody":"OK"}
JSON
URLS="" PREFIXES="" PATTERNS=""
if run_purge; then ok "非 JSON 回應仍成功"; else bad "非 JSON 回應仍成功"; fi
assert_equals "$(output_value mode)" "" "非 JSON 回應時 mode 為空"
assert_equals "$(output_value removed)" "" "非 JSON 回應時 removed 為空"

# ── 10. 伺服器 400：錯誤訊息要透出 ───────────────────────
echo "10. 伺服器 400（all 與 urls 併用）"
reset_request
set_response <<'JSON'
{"status":400,"body":{"error":"all cannot be combined with urls/prefixes/patterns"}}
JSON
URLS="/a.css" PREFIXES="" PATTERNS=""
if run_purge; then bad "400 應失敗"; else ok "400 時 exit code 非 0"; fi
assert_contains "${LOG}" "HTTP 400" "錯誤訊息含 HTTP 狀態"
assert_contains "${LOG}" "all cannot be combined" "錯誤訊息含伺服器回應"
assert_equals "$(cat "${OUT}")" "" "失敗時不寫 outputs"

# ── 11. upload-ssl 不受 purge 輸入影響 ───────────────────
echo "11. upload-ssl 帶 urls 時行為不變"
reset_request
set_response <<'JSON'
{"status":200,"body":{"ok":true}}
JSON
URLS="/a.css" PREFIXES="" PATTERNS=""
: >"${OUT}"
if env \
  FURCDN_ACTION="upload-ssl" \
  FURCDN_API_KEY="fck_test_key" \
  FURCDN_DOMAIN_ID="123" \
  FURCDN_BASE_URL="${BASE}" \
  FURCDN_PURGE_URLS="${URLS}" \
  FURCDN_PURGE_PREFIXES="${PREFIXES}" \
  FURCDN_PURGE_PATTERNS="${PATTERNS}" \
  FURCDN_CERT="CERT-PEM" \
  FURCDN_KEY="KEY-PEM" \
  GITHUB_OUTPUT="${OUT}" \
  bash "${INLINE}" >"${LOG}" 2>&1; then
  ok "upload-ssl 成功"
else
  bad "upload-ssl 成功"
fi
assert_equals "$(request_field '.path')" "/api/v1/domains/123/ssl" "upload-ssl endpoint 不變"
assert_contains "${SERVER_ROOT}/body.bin" 'CERT-PEM' "upload-ssl body 含 cert"
assert_not_contains "${OUT}" "mode=" "upload-ssl 不寫 purge outputs"

# ── 12. 靜態檢查 inline 區塊 ─────────────────────────────
echo "12. inline 區塊靜態檢查"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -S style "${INLINE}"; then
    ok "inline step 通過 shellcheck"
  else
    bad "inline step 通過 shellcheck"
  fi
fi
if bash -n "${INLINE}"; then ok "inline step 通過 bash -n"; else bad "inline step 通過 bash -n"; fi

echo
echo "通過 ${PASS} 項，失敗 ${FAIL} 項"
[[ "${FAIL}" -eq 0 ]]
