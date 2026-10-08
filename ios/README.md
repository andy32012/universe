# iPad／iPhone App

App 是一個外殼：用 `WKWebView` 執行跟網站相同的 `index.html`。遊戲檔案和 `assets/` 會打包進 App，從 `universe://localhost/` 提供給頁面，所以不用網路也能玩。畫面效能跟 Safari 相同。

建置在 GitHub 的 Mac 主機上進行（`.github/workflows/ios.yml`），不需要自己的 Mac：

- 每次推送遊戲檔案或 `ios/`，都會編譯一次，並保留一個未簽名的 `Universe-unsigned.ipa`，可以用免費的 Apple ID 安裝（見下方「免費安裝」）。
- 推送到 `main` 時，如果「TestFlight」一節的四個 secret 都設好了，就會改成簽名並上傳到 TestFlight，成為新版本。也可以在 GitHub 的「Actions → iPad App → Run workflow」手動執行。

## 免費安裝（需要一台 Windows 或 Mac 電腦）

用免費的 Apple ID 簽名，不用加入 Apple Developer Program。限制是裝好的 App **7 天後就打不開**，要重新安裝一次；而且同時最多只能裝 3 個這樣的 App。

1. **下載 App**：登入 GitHub 後，到「Actions → iPad App」，點最新一次成功的執行，在最下方「Artifacts」下載 `Universe-unsigned-ipa`，解壓縮後會得到 `Universe-unsigned.ipa`。
2. **準備電腦**：Windows 要先安裝 Apple 官網下載的 iTunes 和 iCloud（Sideloadly 下載頁上有「Web iTunes 64-bit」「Web iCloud」連結；Microsoft Store 版不能用，裝過的話要先移除），再安裝 [Sideloadly](https://sideloadly.io)（或 AltStore）。
3. **安裝**：用傳輸線把 iPad 接上電腦，在 iPad 上按「信任」。把 `.ipa` 拖進 Sideloadly，輸入 Apple ID，按「Start」。建議用另一個 Apple ID，不要用主要帳號，因為密碼會交給這個第三方工具。
4. **開啟開發者模式**：在 iPad 的「設定 → 隱私權與安全性 → 開發者模式」打開，iPad 會重新開機，開機後按「開啟」確認。
5. **信任開發者**：到「設定 → 一般 → VPN 與裝置管理」，點你的 Apple ID，按「信任」。

更新時下載新的 `.ipa`，用同樣的方法再裝一次就好，遊戲設定會保留。7 天到期時也是重新裝一次；Sideloadly 有自動續簽的選項，但電腦要開著，而且要跟 iPad 在同一個網路。

## TestFlight（Apple Developer Program，每年 99 美元）

在 iPad 的 Safari 就能完成設定：

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

### 更新

改好遊戲並推送到 `main` 之後，GitHub 會自動建置、上傳新版本，版號使用 workflow 的執行次數。新版本通常十幾分鐘後會出現在 TestFlight；開啟 TestFlight 的「自動更新」，iPad 就會自己更新。

- TestFlight 的每個版本 90 天後會過期，到時候重新推送或手動執行一次即可。
- 上架 App Store 的話，每次更新都要先通過 Apple 審核。
