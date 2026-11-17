# verify-loop

**給「指揮 AI 寫程式、但自己不看程式碼」的人的驗證工作法。**

如果你是靠跟 Claude Code、Codex、Gemini CLI 對話來做軟體，你沒辦法自己審程式碼。所以要讓系統替你審：AI 收工前先跑測試、權限依「做錯能不能救回來」來分、同樣的錯第二次出現就變成自動檢查，而不是在 `AGENTS.md` 多寫一行。

[English](README.md) · [方法（中文）](docs/METHOD.zh-TW.md) · [致謝](CREDITS.md)

## 內容

| 元件 | 做什麼 |
|---|---|
| `skills/verify-loop` | 說「verify」。模型自己選模式：**start** 開工前先定 3–5 個檢查點；**setup** 盤點專案護欄；**map** 功能地圖＋能操作真 app 的工具；**triage** 把錯變成檢查；**done** 交付前附證據、爆炸半徑、依風險派審。 |
| `skills/debug` | 說「debug」。模型自己分流：一般 bug、效能、狀態與時序、改動會影響哪裡。 |
| `hooks/stop-verify.sh` | 停止 hook。AI 要收工時，若登記的專案有改到程式，就跑該專案的檢查。失敗或超時 → `exit 2`，AI 必須繼續修（最多擋 3 次）。設了 `tests_re` 時，同一批改動又改程式又改既有測試也會被擋。hook 自己壞掉時不會卡住 session。 |
| `tools/codex-dispatch.sh` | 只接受白名單參數的 `codex exec` 包裝：唯讀或可寫工作區、預設斷網、不載入使用者設定、報告只能寫到安全位置。 |
| `tools/verify-evidence.sh` | 跑檢查並產生綁 commit 的證據段：SHA、指令、結束碼、log 雜湊、有沒有改到既有測試。工作區不乾淨就拒跑。 |
| `docs/METHOD.zh-TW.md` | 一頁說完方法。 |

安裝與設定步驟請看 [README.md](README.md)（指令相同）。專案登記的 key 是 `owner/repo`，例如 `alice/shop`，別人同名的 repo 不會被誤判。

## 注意
- 停止 hook 用你的帳號權限、在 Claude Code 沙盒外跑測試指令；AI 能改 `package.json` 或測試，hook 之後會照跑。只登記你信任的 repo，並留意測試腳本的改動。
- 只要登記的 repo 有改動（包括你自己沒做完的），hook 就會觸發。
- Codex 唯讀模式仍讀得到你帳號能讀的所有檔案；派工腳本限制的是寫入和網路，不是讀取。
- 測試會重置資料庫的專案，`verify` 一定要指向拋棄式資料庫。
- 這是工作法，不是保證。高風險改動（錢、登入、刪資料）仍要兩道獨立 AI 審查加上能退版。

## 授權
MIT。靈感來自 Lydia Hallie 與 Lauren Tan 的公開演講，部分 skill 步驟改寫自 Lauren Tan 以 MIT 授權釋出的 pstack；與兩位及其公司無關，也未經其背書。見 [CREDITS](CREDITS.md)。
