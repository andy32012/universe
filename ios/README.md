# iPad／iPhone App

App 是一個外殼：用 `WKWebView` 執行跟網站相同的 `index.html`。遊戲檔案和 `assets/` 會打包進 App，從 `universe://localhost/` 提供給頁面，所以不用網路也能玩。畫面效能跟 Safari 相同。

建置在 GitHub 的 Mac 主機上進行（`.github/workflows/ios.yml`），不需要自己的 Mac：

- 每次推送遊戲檔案或 `ios/`，都會檢查 App 能不能編譯成功（不簽名）。
- 推送到 `main` 時，如果下面四個 secret 都設好了，就會簽名並上傳到 TestFlight，成為新版本。也可以在 GitHub 的「Actions → iPad App → Run workflow」手動執行。

## 第一次設定（在 iPad 的 Safari 就能完成）

1. **加入 Apple Developer Program**（每年 99 美元）：可以用 App Store 上的「Apple Developer」App 申請。
2. **註冊 Bundle ID**：到 developer.apple.com →「Certificates, Identifiers & Profiles」→「Identifiers」→「+」→「App IDs」→「App」，選「Explicit」，填入 `io.github.andy32012.universe`。
   如果要改用別的 ID，請到 GitHub repo 的「Settings → Secrets and variables → Actions → Variables」新增 `IOS_BUNDLE_ID`。
3. **建立 App**：到 App Store Connect →「App」→「+」→「新增 App」，平台選 iOS，Bundle ID 選上一步註冊的那個。
4. **建立 API 金鑰**：到 App Store Connect →「使用者與存取權限」→「整合」→「App Store Connect API」→ 產生金鑰，存取權限選「**Admin**」（自動簽名需要這個權限）。
   - 記下 **Issuer ID** 和 **Key ID**。
   - 下載 `.p8` 檔。**這個檔案只能下載一次。**想看內容的話，可以在「檔案」App 裡把副檔名改成 `.txt`，再打開複製文字。
5. **找到 Team ID**：到 developer.apple.com →「Account」→「Membership details」。
6. **把資料存到 GitHub**：打開 repo 的「Settings → Secrets and variables → Actions → New repository secret」，新增以下四個：

   | 名稱 | 內容 |
   |---|---|
   | `ASC_KEY_P8` | `.p8` 檔的完整內容（包含 `-----BEGIN PRIVATE KEY-----` 那兩行） |
   | `ASC_KEY_ID` | Key ID |
   | `ASC_ISSUER_ID` | Issuer ID |
   | `APPLE_TEAM_ID` | Team ID |

7. 在 iPad 上安裝 **TestFlight**。到 App Store Connect 的 App →「TestFlight」→ 建立內部測試群組，把自己加進去。

## 更新

改好遊戲並推送到 `main` 之後，GitHub 會自動建置、上傳新版本，版號使用 workflow 的執行次數。新版本通常十幾分鐘後會出現在 TestFlight；開啟 TestFlight 的「自動更新」，iPad 就會自己更新。

- TestFlight 的每個版本 90 天後會過期，到時候重新推送或手動執行一次即可。
- 上架 App Store 的話，每次更新都要先通過 Apple 審核。
