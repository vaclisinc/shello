# herdr-ios-app

一個類似 [Moshi](https://getmoshi.app) 的 iOS 終端機 App，用 SSH 連到你的機器、直接開 [herdr](https://github.com/ogulcancelik/herdr)，並且在手機上監看所有 coding agent（Claude Code、Codex…）的狀態。

## 功能

- **SSH 終端機**：用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 渲染（xterm-256color、滑鼠、bracketed paste），鍵盤上方有 `esc`、黏滯修飾鍵 `⇧` / `ctrl` / `alt`（點一下只套用到下一個鍵，連點兩下鎖定）、`⇧tab`、`⇧⏎`、方向鍵、home/end/pgup/pgdn、`^B`（herdr prefix）、`^C`、貼上。herdr 啟用 kitty 鍵盤協定時會用 CSI u 編碼送出組合鍵，所以 Shift+Enter、Shift+Tab 等能正確傳到 Claude Code / Codex。
- **免費、無次數限制**：沒有用量上限或訂閱。
- **自動開 herdr**：連線後自動執行 `herdr`（啟動或 reattach）。herdr 本身會在伺服器上保留 session，所以斷線、換網路、App 被系統砍掉之後，回到前景會自動重連並接回原本的畫面 —— 這是 Moshi 用 mosh 做到的體驗，這裡靠 herdr 的持久 session 達成。
- **Agents 收件匣**：另開一條 SSH exec channel 定期跑 `herdr api snapshot`，列出所有 agent，依急迫程度排序（blocked → done → working → idle）。
- **不用進終端機就能回應 agent**：讀取 agent 最近輸出（`herdr agent read`）、一鍵 Approve / 1 / 2 / 3 / Reject（`herdr agent send-keys`）、直接送 prompt（`herdr agent prompt`）、或跳到該 pane（`herdr agent focus`）。
- **通知**：agent 進入 `blocked`（等你核准）或 `working → done`（做完了）時發本機通知；正在看該主機時改成震動回饋。
- **金鑰管理**：在裝置上產生 ed25519 金鑰，或匯入 OpenSSH 格式的 ed25519 / RSA 私鑰（支援 passphrase）。私鑰與密碼只存在 iOS Keychain（`ThisDeviceOnly`）。
- **主機金鑰驗證**：TOFU（第一次連線顯示 SHA256 fingerprint 讓你確認），金鑰改變時跳出警告。

## 架構

```
Packages/HerdrKit/          純邏輯 Swift package（可在 macOS 上 `swift test`）
  HerdrModels.swift         herdr API 的 Codable 模型（對應 herdr src/api/schema）
  HerdrCommand.swift        組 herdr CLI 指令（shell quoting、PATH 修正）＋ 回應解析
  AgentTransitions.swift    比對兩次 snapshot，產生「需要你」/「完成」事件
  SSHConnection.swift       Citadel SSH：exec（回傳 exit code/stdout/stderr）＋ PTY shell
  SSHKeys.swift             金鑰產生、匯入、OpenSSH 公鑰格式、fingerprint
  KnownHosts.swift          TOFU host key 驗證
  Keychain.swift            Keychain 包裝
HerdrMobile/                SwiftUI App
  Terminal/                 TerminalSession（PTY + agent 輪詢）、SwiftTerm 包裝、鍵盤工具列
  Views/                    主機列表、主機編輯、金鑰、Session（終端機 / Agents 分頁）、Agent 詳細頁
project.yml                 XcodeGen 專案定義
```

## 建置

需要 macOS + Xcode 16 以上、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
xcodegen generate
open HerdrMobile.xcodeproj
```

在 Xcode 裡選你的 Team（Signing & Capabilities）後即可跑在模擬器或實機上。

跑 HerdrKit 的單元測試：

```sh
cd Packages/HerdrKit && swift test
```

## 伺服器端

```sh
curl -fsSL https://herdr.dev/install.sh | sh
```

App 預設會在 `~/.local/bin`、`~/.cargo/bin`、`~/.nix-profile/bin`、`/opt/homebrew/bin`、`/usr/local/bin` 找 `herdr`；裝在別處的話，在主機設定填絕對路徑。若用具名 session（`herdr --session work`），也在主機設定填 session 名稱。

## 已知限制 / 下一步

- **沒有 mosh**：目前只有 SSH。斷線靠自動重連＋herdr reattach 補足。要加 mosh 需要把 mosh client（C++/protobuf）編進 App。
- **背景通知**：iOS 會在 App 進背景約 30 秒後暫停網路，之後的 agent 狀態變化收不到。要做到 Moshi 那樣的真正推播，需要伺服器端 hook（例如 herdr 的 notification/integration 加上 ntfy 或 APNs relay）。
- 語音輸入目前用 iOS 鍵盤內建的聽寫；尚未整合 on-device Whisper。
- 尚未支援 ECDSA 金鑰、跳板機（ProxyJump）、port forwarding。
