# github-action

[FurCDN](https://www.furcdn.us) 開放 API 的 GitHub Action。從 workflow 直接刷快取、上傳 SSL 憑證、部署靜態網站（FurCDN Pages）。

完整 API 文檔：<https://docs.furcdn.us/api>

## 使用

把 API key 存成 repository secret，然後在 workflow 引用：

```yaml
- uses: FurCDN/github-action@v1
  with:
    action: purge
    api-key: ${{ secrets.FURCDN_API_KEY }}
    domain-id: 123
```

> API key 在 FurCDN 後台建立（`fck_...`）。`base-url` 預設為 `https://cdn.taipei`，一般不需要改。

### 刷快取

```yaml
name: Deploy
on: [push]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # build & deploy ...
      - uses: FurCDN/github-action@v1
        with:
          action: purge
          api-key: ${{ secrets.FURCDN_API_KEY }}
          domain-id: 123
```

### Vercel 部署成功後自動刷快取

監聽 GitHub 的 `deployment_status` 事件，當 Vercel Production 部署成功時自動 purge。
（前提：Vercel 專案已透過 GitHub 整合連接 — 這樣 Vercel 才會回寫 GitHub Deployment 狀態。）

```yaml
name: FurCDN Purge

on:
  deployment_status:

jobs:
  purge:
    if: >-
      github.event.deployment_status.state == 'success' &&
      github.event.deployment_status.environment == 'Production'
    runs-on: ubuntu-latest
    steps:
      - uses: FurCDN/github-action@v1
        with:
          action: purge
          api-key: ${{ secrets.FURCDN_API_KEY }}
          domain-id: 123
```

多個域名可以用 matrix 並行 purge：

```yaml
jobs:
  purge:
    if: >-
      github.event.deployment_status.state == 'success' &&
      github.event.deployment_status.environment == 'Production'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        domain-id: [31, 32]
    steps:
      - uses: FurCDN/github-action@v1
        with:
          action: purge
          api-key: ${{ secrets.FURCDN_API_KEY }}
          domain-id: ${{ matrix.domain-id }}
```

> ⚠️ 含 `on: deployment_status` 的 workflow 檔案**必須先合進預設分支**（通常是 `main`），否則 GitHub 不會觸發；第一次接入時記得直推 `main`。

### 上傳 SSL 憑證

```yaml
- uses: FurCDN/github-action@v1
  with:
    action: upload-ssl
    api-key: ${{ secrets.FURCDN_API_KEY }}
    domain-id: 123
    cert: ${{ secrets.FURCDN_SSL_CERT }}
    key:  ${{ secrets.FURCDN_SSL_KEY }}
```

`cert` 與 `key` 為 PEM 字串，建議透過 secrets 傳入。

### 部署 Pages 靜態網站

把建置產物（預設 `dist/`）打包上傳到 FurCDN Pages。

> **內測中**：Pages 需要內測碼。請先到 FurCDN 後台「Pages」頁面輸入內測碼解鎖，或執行 `furcdn pages beta redeem <code>`；未解鎖時 API 會回 `403 pages_beta_required`。

> **站點沒有公開網址**：FurCDN Pages 不會給站點一個共用網域，內容只會出現在你自己的網域上。第一次使用時請先在 FurCDN 後台「Pages」頁面綁定網域，或執行 `furcdn pages bind`；部署成功後即在你綁定的網域生效。

基本用法（分支等於站點的 production branch 時，部署成功後自動上線）：

```yaml
name: Deploy Pages
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: npm ci && npm run build
      - uses: FurCDN/github-action@v1
        id: pages
        with:
          action: pages-deploy
          api-key: ${{ secrets.FURCDN_API_KEY }}
          site: my-site
          dir: dist
          branch: ${{ github.ref_name }}
          message: ${{ github.event.head_commit.message }}
      - run: echo "已部署 deployment #${{ steps.pages.outputs.deployment-id }}（${{ steps.pages.outputs.status }}）"
```

`branch` 建議一律傳 `${{ github.ref_name }}`：等於站點的 production branch 時該次部署會自動上線；其他分支的 deployment 只會被儲存，不會影響正式站，需要時再到後台或執行 `furcdn pages activate <site> <deployment-id>` 啟用。

#### 第一次部署時自動建站

站點還沒建立時加上 `create-site: true`（等同後台的「建立站點」；slug 需為 3–40 個小寫英數字與 `-`）：

```yaml
- uses: FurCDN/github-action@v1
  with:
    action: pages-deploy
    api-key: ${{ secrets.FURCDN_API_KEY }}
    site: my-site
    dir: dist
    branch: ${{ github.ref_name }}
    create-site: true
```

上傳前 Action 會先在本機檢查（提早失敗，不用等上傳）：

- `site` 格式（`^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$`）
- `dir` 存在且根目錄有 `index.html`
- 目錄內容 ≤ 20 MB、檔案數 ≤ 2000（不含 `.git`、`node_modules`、`.DS_Store`）
- 不含符號連結（symlink）：FurCDN Pages 只接受一般檔案，偵測到會列出前 5 個路徑並中止

封存檔為 tar.gz，上傳時自動排除 `.git`、`node_modules`、`.DS_Store`。

> 不支援符號連結（symlink）。若建置工具（例如 pnpm、Vite 的 linked workspace）在輸出目錄產生 symlink，請改用 `cp -rL`／`rsync -L` 展開成實體檔案後再部署，否則上傳前就會失敗（伺服器端也會以 `400 pages_bad_archive` 拒絕）。

若內容掃描判定需要人工審核，API 會回 `202` 與 `status: held`：step 仍算成功，但會印出 warning，管理員核准後才上線。

## Inputs

| 名稱 | 必填 | 預設 | 說明 |
|---|---|---|---|
| `action` | ✅ | — | 操作類型：`purge`、`upload-ssl` 或 `pages-deploy` |
| `api-key` | ✅ | — | FurCDN API key (`fck_...`) |
| `domain-id` | purge / upload-ssl 必填 | `''` | 目標域名 ID |
| `cert` | upload-ssl 必填 | `''` | PEM 憑證字串 |
| `key` | upload-ssl 必填 | `''` | PEM 私鑰字串 |
| `site` | pages-deploy 必填 | `''` | Pages 站點 slug |
| `dir` | — | `dist` | 要部署的目錄（根目錄需有 `index.html`） |
| `branch` | — | `''` | 分支名稱；空值代表站點的 production branch。建議傳 `${{ github.ref_name }}`（非生產分支只儲存、不自動上線） |
| `message` | — | `''` | 部署訊息（顯示在後台） |
| `create-site` | — | `false` | 站點不存在時自動建立 |
| `base-url` | — | `https://cdn.taipei` | API base URL |

## Outputs

| 名稱 | 說明 |
|---|---|
| `result` | FurCDN API 回應的原始 JSON 內容 |
| `deployment-id` | Pages deployment ID（`pages-deploy`） |
| `status` | 部署狀態：`ready` 或 `held`（`pages-deploy`） |

```yaml
- id: purge
  uses: FurCDN/github-action@v1
  with:
    action: purge
    api-key: ${{ secrets.FURCDN_API_KEY }}
    domain-id: 123

- run: echo "${{ steps.purge.outputs.result }}"
```

```yaml
- id: pages
  uses: FurCDN/github-action@v1
  with:
    action: pages-deploy
    api-key: ${{ secrets.FURCDN_API_KEY }}
    site: my-site
    branch: ${{ github.ref_name }}

- run: echo "deployment ${{ steps.pages.outputs.deployment-id }}：${{ steps.pages.outputs.status }}"
```

## 錯誤處理

非 2xx 回應會讓 step 失敗（exit code 非 0），並在 log 中印出 HTTP 狀態與 API 錯誤訊息：

```
::error::FurCDN API returned HTTP 401
{"error":"invalid api key"}
```

`pages-deploy` 的錯誤會帶上伺服器的 `code`，內容掃描擋下的部署還會列出 `reasons`：

```
::error::FurCDN Pages 部署失敗：HTTP 422 — 內容疑似釣魚網站，已拒絕部署（code=pages_content_blocked）
::error::內容掃描原因：登入表單將密碼送往外部網域；冒用品牌名稱
```

## 開發

`pages-deploy` 的實作在 `scripts/pages-deploy.sh`，測試會起一個本機假 API 後端實際跑完整流程（需要 `bash`、`curl`、`tar`、`jq`、`python3`）：

```bash
bash scripts/test-pages-deploy.sh   # 整合測試
shellcheck scripts/*.sh             # 靜態檢查
```

CI（`.github/workflows/test.yml`）會跑這兩項，並驗證 `action.yml` 的 inputs/outputs。

## License

MIT
