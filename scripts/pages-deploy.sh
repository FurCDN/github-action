#!/usr/bin/env bash
# FurCDN Pages 部署腳本。
#
# 由 action.yml 在 action=pages-deploy 時呼叫，也可獨立執行（測試用）。
# 需要的環境變數：
#   FURCDN_API_KEY      FurCDN API key（fck_...）
#   FURCDN_BASE_URL     API base URL，例如 https://cdn.taipei
#   FURCDN_SITE         站點 slug
#   FURCDN_DIR          要部署的目錄（預設 dist）
#   FURCDN_BRANCH       分支名稱（可空，伺服器會用站點的 productionBranch）
#   FURCDN_MESSAGE      部署訊息（可空）
#   FURCDN_CREATE_SITE  站點不存在時是否自動建立（true/false，預設 false）
#   GITHUB_OUTPUT       GitHub Actions 的 step output 檔（必填）
set -euo pipefail

# 與 furcdn-master/lib/pages/constants.ts 保持一致的上傳前限制
readonly PAGES_SITE_MAX_BYTES=20971520   # 20 MiB：單一站點（解壓後）上限
readonly PAGES_MAX_FILES=2000            # 單一 deployment 檔案數上限

readonly SITE="${FURCDN_SITE:-}"
readonly DIR="${FURCDN_DIR:-dist}"
readonly BRANCH="${FURCDN_BRANCH:-}"
readonly MESSAGE="${FURCDN_MESSAGE:-}"
readonly CREATE_SITE_RAW="${FURCDN_CREATE_SITE:-false}"
readonly API_KEY="${FURCDN_API_KEY:-}"
readonly BASE_URL="${FURCDN_BASE_URL%/}"

die() {
  echo "::error::$*" >&2
  exit 1
}

warn() {
  echo "::warning::$*" >&2
}

# 避免 API key 出現在 log
echo "::add-mask::${API_KEY}"

# ── 參數驗證 ────────────────────────────────────────────────
[[ -n "${API_KEY}" ]] || die "缺少 api-key。請把 FurCDN API key 存成 secret 後以 api-key 傳入。"
[[ -n "${BASE_URL}" ]] || die "缺少 base-url。"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT 未設定，無法寫入 step outputs}"

for tool in curl jq tar; do
  command -v "${tool}" >/dev/null 2>&1 || die "找不到 ${tool}，請確認 runner 環境。"
done

if [[ ! "${SITE}" =~ ^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$ ]]; then
  die "site '${SITE}' 格式不正確：需為 3–40 個字元，僅限小寫英數字與 -，且不可用 - 開頭或結尾。"
fi

[[ -d "${DIR}" ]] || die "找不到部署目錄 '${DIR}'。請先 checkout 並完成建置（或用 dir 指定輸出目錄）。"
[[ -f "${DIR}/index.html" ]] || die "部署目錄 '${DIR}' 缺少根目錄 index.html；FurCDN Pages 需要 index.html 作為首頁。"

# 伺服器只接受一般檔案：symlink/hardlink/裝置檔一律 400 pages_bad_archive。
# 先在本機擋下（被 tar 排除的 .git、node_modules、.DS_Store 不在此列）。
mapfile -t symlinks < <(
  find "${DIR}" \
    \( -name '.git' -o -name 'node_modules' -o -name '.DS_Store' \) -prune -o \
    -type l -print
)

if (( ${#symlinks[@]} > 0 )); then
  echo "偵測到 ${#symlinks[@]} 個符號連結（僅列前 5 個）：" >&2
  printf '  %s\n' "${symlinks[@]:0:5}" >&2
  die "部署目錄包含符號連結，FurCDN Pages 不支援（共 ${#symlinks[@]} 個）；請在打包前移除或改成實體檔案。"
fi

create_site=0
case "$(printf '%s' "${CREATE_SITE_RAW}" | tr '[:upper:]' '[:lower:]')" in
  true | 1 | yes) create_site=1 ;;
  '' | false | 0 | no) create_site=0 ;;
  *) die "create-site 只接受 true 或 false（目前為 '${CREATE_SITE_RAW}'）。" ;;
esac

# ── 本地上傳前檢查（與伺服器相同的限制，提早失敗） ──────────
# 量測範圍與 tar 的排除規則一致：.git、node_modules、.DS_Store 不計入。
read -r total_bytes total_files < <(
  find "${DIR}" \
    \( -name '.git' -o -name 'node_modules' -o -name '.DS_Store' \) -prune -o \
    -type f -printf '%s\n' |
    awk '{ sum += $1; count += 1 } END { printf "%d %d\n", sum, count }'
) || die "無法讀取目錄 '${DIR}' 的檔案清單。"

if (( total_bytes > PAGES_SITE_MAX_BYTES )); then
  die "站點大小 $(( total_bytes / 1024 / 1024 )) MB 超過單站上限 20 MB（共 ${total_files} 個檔案）。請縮減 ${DIR} 的內容。"
fi

if (( total_files > PAGES_MAX_FILES )); then
  die "檔案數 ${total_files} 超過單站上限 ${PAGES_MAX_FILES}。請縮減 ${DIR} 的內容。"
fi

echo "打包 ${DIR}（${total_files} 個檔案，$(( total_bytes / 1024 )) KB）..."

archive_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
archive="$(mktemp "${archive_dir}/furcdn-pages-XXXXXX.tar.gz")"
response_file="$(mktemp "${archive_dir}/furcdn-pages-response-XXXXXX.json")"
cleanup() {
  rm -f "${archive}" "${response_file}"
}
trap cleanup EXIT

# 封存內容相對於 DIR 根目錄（-C "$DIR" .）；--owner/--group 讓 tar 標頭固定，
# 同一份內容在不同 runner 產生相同雜湊。伺服器會忽略開頭的 ./ 前綴。
tar -czf "${archive}" \
  --exclude='.git' \
  --exclude='.DS_Store' \
  --exclude='node_modules' \
  --owner=0 --group=0 --numeric-owner \
  -C "${DIR}" . || die "打包 '${DIR}' 失敗。"

# ── 組 query（message/branch 需 URL-encode） ────────────────
urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

query="via=action"
if [[ -n "${BRANCH}" ]]; then
  query+="&branch=$(urlencode "${BRANCH}")"
fi
if [[ -n "${MESSAGE}" ]]; then
  query+="&message=$(urlencode "${MESSAGE}")"
fi
if (( create_site == 1 )); then
  query+="&create=1"
fi

endpoint="${BASE_URL}/api/v1/pages/sites/${SITE}/deployments"
echo "上傳到 ${endpoint}${BRANCH:+（branch=${BRANCH}）}..."

if ! http_code=$(curl -sS --max-time 300 \
  -o "${response_file}" \
  -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/gzip' \
  --data-binary "@${archive}" \
  "${endpoint}?${query}"); then
  die "無法連線到 FurCDN API（${BASE_URL}）。請確認網路與 base-url 是否正確。"
fi

body="$(cat "${response_file}")"

# ── 失敗處理 ────────────────────────────────────────────────
json_field() {
  jq -r "$1 // empty" <<<"${body}" 2>/dev/null || true
}

case "${http_code}" in
  2*) ;;
  *)
    api_error="$(json_field '.error')"
    api_code="$(json_field '.code')"
    api_reasons="$(jq -r '(.reasons // []) | join("；")' <<<"${body}" 2>/dev/null || true)"

    detail="${api_error:-未知錯誤}"
    if [[ -n "${api_code}" ]]; then
      detail+="（code=${api_code}）"
    fi
    echo "${body}" >&2
    echo "::error::FurCDN Pages 部署失敗：HTTP ${http_code} — ${detail}" >&2
    if [[ -n "${api_reasons}" ]]; then
      echo "::error::內容掃描原因：${api_reasons}" >&2
    fi
    exit 1
    ;;
esac

# ── 解析回應並寫 outputs ────────────────────────────────────
jq -e . >/dev/null 2>&1 <<<"${body}" || die "FurCDN API 回應不是合法 JSON（HTTP ${http_code}）：${body}"

deployment_id="$(json_field '.deployment.id')"
status="$(json_field '.deployment.status')"
url="$(json_field '.deployment.url')"
[[ -n "${url}" ]] || url="$(json_field '.site.url')"
preview_url="$(json_field '.deployment.previewUrl')"

if [[ -z "${deployment_id}" || -z "${status}" ]]; then
  die "FurCDN API 回應缺少 deployment 資訊：${body}"
fi

{
  printf 'deployment-id=%s\n' "${deployment_id}"
  printf 'url=%s\n' "${url}"
  printf 'preview-url=%s\n' "${preview_url}"
  printf 'status=%s\n' "${status}"
  printf 'result<<__FURCDN_EOF__\n'
  printf '%s\n' "${body}"
  printf '__FURCDN_EOF__\n'
} >>"${GITHUB_OUTPUT}"

echo "HTTP ${http_code}"
echo "${body}"

if [[ "${http_code}" == "202" || "${status}" == "held" ]]; then
  warn "部署 #${deployment_id} 已上傳但進入待審核（內容掃描），管理員核准前不會上線。預覽網址：${preview_url}"
else
  echo "部署成功：deployment #${deployment_id}（status=${status}）"
  if [[ -n "${url}" ]]; then
    echo "網址：${url}"
  fi
  if [[ -n "${preview_url}" ]]; then
    echo "預覽：${preview_url}"
  fi
fi
