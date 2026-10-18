#!/usr/bin/env bash
# scripts/pages-deploy.sh 的整合測試：起一個本機假 FurCDN API，實際執行部署腳本。
# 需要：bash、curl、tar、jq、python3。用法：bash scripts/test-pages-deploy.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/pages-deploy.sh"

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
SITE_DIR="${WORK}/site"
OUT="${WORK}/github_output"
LOG="${WORK}/deploy.log"
mkdir -p "${SERVER_ROOT}" "${SITE_DIR}"

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

# ── 測試資料 ────────────────────────────────────────────────
build_site() {
  rm -rf "${SITE_DIR}"
  mkdir -p "${SITE_DIR}/assets" "${SITE_DIR}/.git" "${SITE_DIR}/node_modules/pkg"
  printf '<!doctype html><title>demo</title>\n' >"${SITE_DIR}/index.html"
  printf 'body{color:#000}\n' >"${SITE_DIR}/assets/app.css"
  printf 'ref: refs/heads/main\n' >"${SITE_DIR}/.git/HEAD"
  printf 'module.exports = 1\n' >"${SITE_DIR}/node_modules/pkg/index.js"
  printf 'junk\n' >"${SITE_DIR}/.DS_Store"
}

set_response() {
  cat >"${SERVER_ROOT}/response.json"
}

run_deploy() {
  : >"${OUT}"
  env \
    FURCDN_API_KEY="fck_test_key" \
    FURCDN_BASE_URL="${BASE}/" \
    FURCDN_SITE="${SITE_SLUG-demo}" \
    FURCDN_DIR="${SITE_DIR}" \
    FURCDN_BRANCH="${SITE_BRANCH-}" \
    FURCDN_MESSAGE="${SITE_MESSAGE-}" \
    FURCDN_CREATE_SITE="${SITE_CREATE-false}" \
    GITHUB_OUTPUT="${OUT}" \
    bash "${SCRIPT}" >"${LOG}" 2>&1
  return $?
}

output_value() {
  # 讀取 GITHUB_OUTPUT 中單行 output 的值
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2) }' "${OUT}"
}

# ── 1. 成功部署（生產分支） ─────────────────────────────────
echo "1. 成功部署（含 branch/message/create，排除 .git 與 node_modules）"
build_site
rm -f "${SERVER_ROOT}/request.json" "${SERVER_ROOT}/body.bin"
set_response <<'JSON'
{"status":201,"body":{"deployment":{"id":42,"siteSlug":"demo","status":"ready","active":false,"branch":"feature/x","url":"https://ignored.example.com","previewUrl":"https://ignored-preview.example.com"},"site":{"id":7,"slug":"demo"}}}
JSON
SITE_SLUG="demo" SITE_BRANCH="feature/x" SITE_MESSAGE="hello world 你好" SITE_CREATE="true"
if run_deploy; then ok "exit code 0"; else bad "exit code 0"; fi
assert_equals "$(output_value deployment-id)" "42" "output deployment-id"
assert_equals "$(output_value status)" "ready" "output status"
assert_not_contains "${OUT}" "url=" "不再提供 url output"
assert_not_contains "${OUT}" "preview-url=" "不再提供 preview-url output"
assert_contains "${OUT}" '"id":42' "output result 為原始 JSON"
assert_contains "${LOG}" "非生產分支" "非生產分支提示需 activate"
assert_contains "${LOG}" "furcdn pages activate demo 42" "提示啟用指令"
assert_contains "${LOG}" "::add-mask::" "API key 有被 mask"

REQUEST="${SERVER_ROOT}/request.json"
assert_equals "$(jq -r '.path' "${REQUEST}")" \
  "/api/v1/pages/sites/demo/deployments?via=action&branch=feature%2Fx&message=hello%20world%20%E4%BD%A0%E5%A5%BD&create=1" \
  "endpoint 與 URL-encode 後的 query"
assert_equals "$(jq -r '.headers["content-type"]' "${REQUEST}")" "application/gzip" "Content-Type"
assert_equals "$(jq -r '.headers["authorization"]' "${REQUEST}")" "Bearer fck_test_key" "Authorization header"
assert_equals "$(jq -r '.bodyLen' "${REQUEST}")" "$(stat -c %s "${SERVER_ROOT}/body.bin")" "body 長度與封存檔一致"
assert_equals "$(head -c 2 "${SERVER_ROOT}/body.bin" | od -An -tx1 | tr -d ' \n')" "1f8b" "body 是 gzip"

LISTING="${WORK}/listing.txt"
tar -tzf "${SERVER_ROOT}/body.bin" >"${LISTING}"
assert_contains "${LISTING}" "./index.html" "封存檔含 ./index.html"
assert_contains "${LISTING}" "./assets/app.css" "封存檔含 ./assets/app.css"
assert_not_contains "${LISTING}" ".git/" "封存檔排除 .git"
assert_not_contains "${LISTING}" "node_modules/" "封存檔排除 node_modules"
assert_not_contains "${LISTING}" ".DS_Store" "封存檔排除 .DS_Store"
OWNERS="${WORK}/owners.txt"
tar -tvzf "${SERVER_ROOT}/body.bin" | awk '{ print $2 }' | sort -u >"${OWNERS}"
assert_equals "$(cat "${OWNERS}")" "0/0" "封存檔 owner/group 固定為 0/0"

# ── 2. 待審核（202 held） ───────────────────────────────────
echo "2. 內容待審核（HTTP 202 + status=held）"
build_site
set_response <<'JSON'
{"status":202,"body":{"held":true,"deployment":{"id":43,"status":"held","active":false},"site":{"id":7,"slug":"demo"}}}
JSON
SITE_SLUG="demo" SITE_BRANCH="" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then ok "held 時 step 仍成功"; else bad "held 時 step 仍成功"; fi
assert_equals "$(output_value status)" "held" "output status=held"
assert_contains "${LOG}" "::warning::" "held 時輸出 warning"
assert_contains "${LOG}" "待審核" "warning 說明待審核"
assert_not_contains "${OUT}" "preview-url=" "held 時沒有 preview-url output"
assert_equals "$(jq -r '.path' "${REQUEST}")" "/api/v1/pages/sites/demo/deployments?via=action" "未傳 branch/message/create 時 query 精簡"

# ── 3. 釣魚判定被擋（422） ──────────────────────────────────
echo "3. 內容掃描判定釣魚（422 pages_content_blocked）"
build_site
set_response <<'JSON'
{"status":422,"body":{"error":"內容疑似釣魚網站，已拒絕部署","code":"pages_content_blocked","reasons":["登入表單將密碼送往外部網域","冒用品牌名稱"]}}
JSON
if run_deploy; then bad "422 應失敗"; else ok "422 時 exit code 非 0"; fi
assert_contains "${LOG}" "::error::" "422 輸出 ::error::"
assert_contains "${LOG}" "code=pages_content_blocked" "錯誤含 code"
assert_contains "${LOG}" "登入表單將密碼送往外部網域" "錯誤含 reasons"

# ── 4. 未解鎖內測（403） ────────────────────────────────────
echo "4. 未取得內測碼（403 pages_beta_required）"
build_site
set_response <<'JSON'
{"status":403,"body":{"error":"FurCDN Pages 仍在內測，請先兌換內測碼","code":"pages_beta_required"}}
JSON
if run_deploy; then bad "403 應失敗"; else ok "403 時 exit code 非 0"; fi
assert_contains "${LOG}" "code=pages_beta_required" "錯誤含 code"
assert_equals "$(cat "${OUT}")" "" "失敗時不寫 outputs"

# ── 5. 本機驗證：slug 格式 ─────────────────────────────────
echo "5. 本機驗證：slug 格式錯誤不發請求"
build_site
rm -f "${SERVER_ROOT}/request.json"
SITE_SLUG="Bad_Slug" SITE_BRANCH="" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then bad "非法 slug 應失敗"; else ok "非法 slug 時 exit code 非 0"; fi
assert_contains "${LOG}" "::error::" "非法 slug 輸出 ::error::"
if [[ -f "${SERVER_ROOT}/request.json" ]]; then bad "非法 slug 不應呼叫 API"; else ok "非法 slug 不呼叫 API"; fi

# ── 6. 本機驗證：缺 index.html ─────────────────────────────
echo "6. 本機驗證：缺根目錄 index.html"
build_site
rm -f "${SITE_DIR}/index.html"
SITE_SLUG="demo" SITE_BRANCH="" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then bad "缺 index.html 應失敗"; else ok "缺 index.html 時 exit code 非 0"; fi
assert_contains "${LOG}" "index.html" "錯誤訊息提到 index.html"

# ── 7. 本機驗證：超過 20MB ────────────────────────────────
echo "7. 本機驗證：目錄超過 20 MB"
build_site
truncate -s 21M "${SITE_DIR}/big.bin"
if run_deploy; then bad "超過 20MB 應失敗"; else ok "超過 20MB 時 exit code 非 0"; fi
assert_contains "${LOG}" "20 MB" "錯誤訊息提到 20 MB"

# ── 8. 本機驗證：檔案數超過 2000 ──────────────────────────
echo "8. 本機驗證：檔案數超過 2000"
build_site
mkdir -p "${SITE_DIR}/many"
for i in $(seq 1 2001); do
  : >"${SITE_DIR}/many/f${i}.txt"
done
if run_deploy; then bad "超過 2000 檔應失敗"; else ok "超過 2000 檔時 exit code 非 0"; fi
assert_contains "${LOG}" "2000" "錯誤訊息提到檔案數上限"

# ── 9. 本機驗證：符號連結（伺服器會 400 pages_bad_archive） ─
echo "9. 本機驗證：目錄含符號連結"
build_site
ln -s /etc/passwd "${SITE_DIR}/leak.txt"
mkdir -p "${SITE_DIR}/node_modules/.bin"
ln -s ../pkg/index.js "${SITE_DIR}/node_modules/.bin/fake"
rm -f "${SERVER_ROOT}/request.json"
SITE_SLUG="demo" SITE_BRANCH="" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then bad "含 symlink 應失敗"; else ok "含 symlink 時 exit code 非 0"; fi
assert_contains "${LOG}" "符號連結" "錯誤訊息提到符號連結"
assert_contains "${LOG}" "leak.txt" "列出 symlink 路徑"
assert_not_contains "${LOG}" "node_modules/.bin/fake" "被 tar 排除的 symlink 不列入"
if [[ -f "${SERVER_ROOT}/request.json" ]]; then bad "含 symlink 不應呼叫 API"; else ok "含 symlink 不呼叫 API"; fi

# ── 10. create-site=false 不帶 create ─────────────────────
echo "10. create-site=false 不帶 create 參數"
build_site
set_response <<'JSON'
{"status":201,"body":{"deployment":{"id":44,"status":"ready","active":true},"site":{"slug":"demo"}}}
JSON
SITE_SLUG="demo" SITE_BRANCH="main" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then ok "create-site=false 成功"; else bad "create-site=false 成功"; fi
assert_equals "$(jq -r '.path' "${REQUEST}")" "/api/v1/pages/sites/demo/deployments?via=action&branch=main" "無 create 參數"
assert_contains "${LOG}" "部署成功" "生產分支部署成功訊息"
assert_not_contains "${LOG}" "非生產分支" "生產分支不顯示 activate 提示"

# ── 11. 非 JSON 回應不崩潰 ────────────────────────────────
echo "11. 非 JSON 回應（例如反向代理錯誤頁）"
build_site
set_response <<'JSON'
{"status":502,"rawBody":"<html>502 Bad Gateway</html>"}
JSON
SITE_SLUG="demo" SITE_BRANCH="" SITE_MESSAGE="" SITE_CREATE="false"
if run_deploy; then bad "502 應失敗"; else ok "502 時 exit code 非 0"; fi
assert_contains "${LOG}" "HTTP 502" "錯誤訊息含 HTTP 狀態"

# ── 12. 既有 purge / upload-ssl inline step 行為不變 ───────
echo "12. 既有 purge / upload-ssl inline step（直接執行 action.yml 的 run 區塊）"
python3 - "${ROOT}/action.yml" "${WORK}" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)

for step in data["runs"]["steps"]:
    if step.get("id") == "run":
        with open(sys.argv[2] + "/inline-run.sh", "w", encoding="utf-8") as out:
            out.write(step["run"])
        break
else:
    raise SystemExit("action.yml 缺少 id=run 的 step")
PY

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -s bash -S style "${WORK}/inline-run.sh"; then
    ok "inline step 通過 shellcheck"
  else
    bad "inline step 通過 shellcheck"
  fi
fi

run_inline() {
  : >"${OUT}"
  env \
    FURCDN_ACTION="$1" \
    FURCDN_API_KEY="fck_test_key" \
    FURCDN_DOMAIN_ID="${2-123}" \
    FURCDN_CERT="${3-}" \
    FURCDN_KEY="${4-}" \
    FURCDN_BASE_URL="${BASE}" \
    GITHUB_OUTPUT="${OUT}" \
    bash "${WORK}/inline-run.sh" >"${LOG}" 2>&1
  return $?
}

set_response <<'JSON'
{"status":200,"body":{"ok":true}}
JSON
rm -f "${SERVER_ROOT}/request.json"
if run_inline purge 123; then ok "purge 成功"; else bad "purge 成功"; fi
assert_equals "$(jq -r '.path' "${REQUEST}")" "/api/v1/domains/123/purge" "purge endpoint 不變"
assert_contains "${OUT}" '{"ok":true}' "purge 的 result output 不變"

rm -f "${SERVER_ROOT}/request.json"
if run_inline upload-ssl 123 "CERT-PEM" "KEY-PEM"; then ok "upload-ssl 成功"; else bad "upload-ssl 成功"; fi
assert_equals "$(jq -r '.path' "${REQUEST}")" "/api/v1/domains/123/ssl" "upload-ssl endpoint 不變"
assert_equals "$(jq -r '.headers["content-type"]' "${REQUEST}")" "application/json" "upload-ssl 用 JSON body"
assert_contains "${SERVER_ROOT}/body.bin" 'CERT-PEM' "upload-ssl body 含 cert"
assert_contains "${SERVER_ROOT}/body.bin" 'KEY-PEM' "upload-ssl body 含 key"

rm -f "${SERVER_ROOT}/request.json"
if run_inline upload-ssl 123 "" ""; then bad "upload-ssl 缺 cert/key 應失敗"; else ok "upload-ssl 缺 cert/key 時 exit code 非 0"; fi
assert_contains "${LOG}" "requires both 'cert' and 'key'" "錯誤訊息不變"

if run_inline bogus 123; then bad "未知 action 應失敗"; else ok "未知 action 時 exit code 非 0"; fi
assert_contains "${LOG}" "Unknown action" "未知 action 錯誤訊息不變"

if run_inline purge "abc"; then bad "非數字 domain-id 應失敗"; else ok "非數字 domain-id 時 exit code 非 0"; fi
assert_contains "${LOG}" "domain-id must be a positive integer" "domain-id 驗證訊息不變"

echo
echo "通過 ${PASS} 項，失敗 ${FAIL} 項"
[[ "${FAIL}" -eq 0 ]]
