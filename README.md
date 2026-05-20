# github-action

[FurCDN](https://www.furcdn.us) 開放 API 的 GitHub Action。從 workflow 直接刷快取、上傳 SSL 憑證。

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

## Inputs

| 名稱 | 必填 | 預設 | 說明 |
|---|---|---|---|
| `action` | ✅ | — | 操作類型：`purge` 或 `upload-ssl` |
| `api-key` | ✅ | — | FurCDN API key (`fck_...`) |
| `domain-id` | ✅ | — | 目標域名 ID |
| `cert` | upload-ssl 必填 | `''` | PEM 憑證字串 |
| `key` | upload-ssl 必填 | `''` | PEM 私鑰字串 |
| `base-url` | — | `https://www.furcdn.us` | API base URL |

## Outputs

| 名稱 | 說明 |
|---|---|
| `result` | FurCDN API 回應的原始 JSON 內容 |

```yaml
- id: purge
  uses: FurCDN/github-action@v1
  with:
    action: purge
    api-key: ${{ secrets.FURCDN_API_KEY }}
    domain-id: 123

- run: echo "${{ steps.purge.outputs.result }}"
```

## 錯誤處理

非 2xx 回應會讓 step 失敗（exit code 非 0），並在 log 中印出 HTTP 狀態與 API 錯誤訊息：

```
::error::FurCDN API returned HTTP 401
{"error":"invalid api key"}
```

## License

MIT
