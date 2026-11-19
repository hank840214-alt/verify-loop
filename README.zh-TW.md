# verify-loop

**給「指揮 AI 寫程式、但自己不看程式碼」的人的驗證工作法。**

如果你是靠跟 Claude Code、Codex、Gemini CLI 對話來做軟體，你沒辦法自己審程式碼。所以要讓系統替你審：AI 收工前先跑測試、權限依「做錯能不能救回來」來分、每個錯都變成自動檢查，而不是在 `AGENTS.md` 多寫一行。

[English](README.md) · [方法（中文）](docs/METHOD.zh-TW.md) · [致謝](CREDITS.md)

## 內容

| 元件 | 做什麼 |
|---|---|
| `skills/verify-loop` | 說「verify」。模型自己選模式：**start** 開工前先定 3–5 個檢查點；**setup** 盤點專案護欄；**map** 功能地圖＋能操作真 app 的工具；**triage** 把錯變成檢查；**done** 交付前附證據、爆炸半徑、依風險派審。 |
| `skills/debug` | 說「debug」。模型自己分流：一般 bug、效能、狀態與時序、改動會影響哪裡。 |
| `hooks/stop-verify.sh` | 停止 hook。AI 要收工時，若登記的專案有改到程式，就跑該專案的檢查。失敗或超時 → `exit 2`，但同一個狀態只擋一次、不重跑，之後 AI 可以收工並看到 NOT VERIFIED。設了 `tests_re` 時，同一批改動又改程式又改既有測試也會被擋一次；它只看還沒 commit 的改動，已 commit 的測試改動由 `verify-evidence.sh` 列給審查者。hook 自己壞掉時不會卡住 session。 |
| `hooks/post-edit-check.sh` | PostToolUse hook（`Edit`、`Write`、`MultiEdit`），第 1 層。在登記且設了 `edit_check` 的專案裡，每次改檔後跑那個快速檢查（例如 `tsc`），只有「檢查失敗，而且輸出裡有一行點名剛改的那個檔」才擋（`exit 2`）。別的檔有錯不管。逾時、找不到工具、hook 自己出錯都不會擋。 |
| `hooks/subagent-verify.sh` | 針對 `SubagentHandback` 的 PreToolUse hook，第 2 層。子代理要交報告前，從它自己的對話紀錄判斷有沒有改到受信任的 checkout，有就跑該專案的檢查。失敗就擋下交報告（`exit 2`），子代理繼續修。每個子代理最多擋 2 次，同一個確切狀態只擋一次。 |
| `tools/codex-dispatch.sh` | 只接受白名單參數的 `codex exec` 包裝：唯讀或可寫工作區、預設斷網（指 Codex 執行的指令；prompt 與圖片仍會送到模型服務；呼叫者可加 `--net`）、不載入使用者設定、可寫模式只能改目前所在的 repo（或你列出的 repo）、報告只能寫到 `<repo>/.scratch/` 或 `/tmp`。 |
| `tools/verify-evidence.sh` | 跑檢查並產生綁 commit 的證據段：SHA、指令、結束碼、log 雜湊、它在 `PATH` 上找到的 `node` 與 `python3`（`--tool <名稱>` 可加列；路徑會遮罩，貼出前仍請看過那一行）、有沒有改到既有測試。同一分支新增後又修改的測試列在獨立標題下。腳本不改 `PATH`：工具那一行出現 shim 或舊版直譯器，就修好 `PATH` 再重跑。工作區不乾淨就拒跑；中途有變動或無法檢查測試改動時結束碼 90（INVALID）。預設不印 log 內容，要附 log 尾段用 `--tail N`；但會印出完整指令，密碼請用環境變數傳，貼到公開 PR 前先看過整段。指令若改檔再改回，本機證據看不出來；真正的關卡是 CI 在乾淨 checkout 上重跑。 |
| `docs/METHOD.zh-TW.md` | 一頁說完方法。 |

安裝：外掛會註冊停止 hook 與新的兩個 hook，專案登記前它們都什麼都不做。設定步驟請看 [README.md](README.md)（指令相同）。專案登記的 key 是 `owner/repo`，例如 `alice/shop`；另外必須填 `roots`：你信任的 checkout 絕對路徑。其他位置的 clone（就算同一個 repo）都不會被執行，hook 會提示並印出該補進 `roots` 的實際路徑。信任的 checkout 底下的 linked worktree 也算信任。選填 `skip_re`：符合的檔案不會觸發檢查（自動產生的檔案、被中斷的測試留下的資料夾）。每次判定都會追加一行到 `~/.claude/state/stop-verify/ledger.tsv`（只在本機、不印出、不含完整路徑）。有子代理、workflow 或 `codex-dispatch.sh` 在跑時會先不檢查，等下一次收工再跑。`STOP_VERIFY_DEADLINE`（120..540 秒，預設 540）是總時間上限。要強制重跑已失敗的狀態：改一個檔案，或刪掉 `<state 資料夾>/<id>.red`。`VERIFY_CHANGED_FILE` 以換行分隔，所以不支援含換行的檔名。**每次改檔後的快速檢查，與子代理交報告前的檢查。** 兩個 hook 讀同一份專案檔、用同樣的 `roots` 信任方式。專案沒填下面的欄位，那個 hook 就不碰它。

```json
{
  "your-name/my-web-app": {
    "roots": ["/home/you/src/my-web-app"],
    "verify": "npx tsc --noEmit && npm test --silent",
    "edit_check": {
      "files_re": "^(src|server)/.*\\.(ts|tsx)$",
      "cmd": "npx tsc --noEmit --pretty false",
      "limit": 20
    },
    "handback_verify": "npx tsc --noEmit && npm test --silent",
    "handback_limit": 420
  }
}
```

- `edit_check`（第 1 層）：`files_re` 是對「相對 repo 根目錄的路徑」的擴充正規式；`cmd` 是在 repo 根目錄跑的 bash 指令，`$EDIT_FILE` 就是那個路徑；`limit` 單位秒（1..22，預設 20）。只有 `cmd` 結束碼非 0、而且輸出有一行點名剛改的檔（整段路徑，相對或絕對都行）才擋，最多顯示 20 行。`cmd` 只報別的檔，這次編輯就放行。請讓工具印出相對 repo 根目錄的路徑。
- `handback_verify`（第 2 層）：改過這個 checkout 的子代理交報告時跑的指令，預設用 `verify`。結束碼非 0 算失敗；124、126、127 或被訊號殺掉算「沒驗完」，交報告照常通過。`$VERIFY_CHANGED_FILE` 列出子代理用編輯工具寫過的檔。
- `handback_limit`：這次執行的秒數上限，超過算「沒驗完」（1..440，預設 420；hook timeout 是 480）。

帳本：`~/.claude/state/post-edit-check/ledger.tsv` 與 `~/.claude/state/subagent-verify/ledger.tsv`（只在本機、不印出）。

登記前先請 AI 跑 `/verify-loop setup`，它會讀測試設定，列出會重置資料庫、部署、寄信或打付費 API 的步驟。

## 伺服器端硬擋：用 CODEOWNERS 保護測試
本機的測試守衛可以被繞過（先 commit 再改測試），交給 GitHub 擋：把 `examples/CODEOWNERS` 複製到 `.github/CODEOWNERS`，填上測試路徑和負責人，預設分支要求 PR 與 Code Owner 審核（管理員也適用）。AI 必須用另一個帳號 push，因為 GitHub 不准帳號核准自己的 PR。公開 repo 免費；私人 repo 需付費方案。

## 注意
- 停止 hook 用你的帳號權限、在 Claude Code 沙盒外跑測試指令；AI 能改 `package.json` 或測試，hook 之後會照跑。信任是看路徑：在登記的資料夾切到別人的分支或 PR，hook 會用你的權限跑那個分支的測試腳本。外部 PR 請用另一份沒登記的 clone；要隔離就讓 `verify` 自己啟動容器或 VM。
- 停止 hook 不會偵測用 skip-worktree／assume-unchanged 藏起來的檔案；evidence 腳本仍會拒絕這種情況。
- 同一個 checkout 同時收工，可能各自跑檢查、各自被擋；另一個 session 記下的通過，可能蓋過這個 session 先前對同一份程式的失敗。
- 只要登記的 repo 有改動（包括你自己沒做完的），hook 就會觸發。失敗不是這個 session 造成時，Claude 被要求說明並停手，但它仍可能去改。
- 第 1 層（`post-edit-check.sh`）在改檔之後才跑，無法還原那次編輯，只能告訴 Claude。只有點名被改檔案的輸出行才會擋，所以不印路徑的工具永遠不會擋。
- 第 2 層（`subagent-verify.sh`）需要 `SubagentHandback` 這個工具，也就是子代理交報告時呼叫的那個。在較新的 Claude Code 上觀察到有它。沒有它的環境裡，這個 hook 永遠不會觸發，什麼都不會檢查。
- 第 2 層面對的是共用的 checkout。失敗可能來自別的 session 的改動，所以擋下時的訊息會這樣說，並要求子代理不要去還原不是自己的改動。
- 第 2 層靠字串比對（`>`、`sed -i`、`mv`、`git checkout` 等）加路徑名稱，找出子代理用 Bash 寫的檔。可能漏掉，也可能把無害的指令算進去。唯讀的 git（`status`、`log`、`diff`、`show`、`stash list`）不算寫入。
- 第 2 層不管子代理改的是哪個檔，都會跑完整的 `handback_verify`。
- Codex 唯讀模式仍讀得到你帳號能讀的所有檔案；派工腳本限制的是寫入和網路，不是讀取。
- 「預設斷網」是派工腳本傳給 Codex 的設定（`sandbox_workspace_write.network_access=false`）；測試只檢查有傳這個設定，沒測實際連線。請在你的 Codex 版本上確認一次。
- 派工腳本在 Claude 沙盒外執行，會從 `PATH` 找 `codex`。它拒絕執行放在目標 repo 或目前 repo 裡的 codex；其他 AI 寫得到的資料夾不要放進 `PATH`。
- 證據段會印出完整指令，加 `--tail N` 時還有 log 尾段。密碼請用環境變數傳，貼到公開 PR 前先看過整段。
- deny 規則只是把 AI 導向派工腳本，不是沙盒。
- `excludedCommands` 只是方便，不是安全邊界。
- 測試會重置資料庫的專案，`verify` 一定要指向拋棄式資料庫。
- 這是工作法，不是保證。高風險改動（錢、登入、刪資料）仍要兩道獨立 AI 審查加上能退版；有懂程式的人時，也請他看。

## 實跑心得

來自頭幾次實跑：一個有伺服器與瀏覽器前端的 app。下面提到的操作工具與它的檢查在那個專案裡，不在這個 repo。

- 「單獨跑都過」不算結論。去失敗的 log 找系統自己印的訊號。每次失敗的前一行都是保護機制的關閉紀錄，根因就在那一行。
- 「機器太忙」要能故意重現。在測試行程裡卡住事件迴圈可以重現；開二十個空轉的 CPU 行程不行。
- 證據要在乾淨的 `PATH` 產生。兩次全套測試各假失敗 44、39 個，原因是舊的系統直譯器和一個攔截 shim。
- 新寫的檢查也會不穩。只留「要驗的那一個訊號」是真的，其餘注入，再把舊錯放回去，看檢查會不會失敗。
- 流程通過不算證明，截圖要看得到功能地圖承諾的東西。有一條流程靠內部狀態通過，但它聲稱的東西不在畫面內；後來又在它被浮層蓋住時通過。那個專案現在要求截圖前後都看得到沒被蓋住的標籤。
- 要操作使用者拿到的那個版本。第一版操作工具 build 時沒開正式功能旗標，四條流程是在使用者看不到的畫面上通過的。
- 圖要對得上程式。截圖上的 commit 編號必須就是那個 commit 的 build。那個專案的操作工具把未提交的 build 標成 `+dirty`，並拒絕別的狀態 build 出來的執行個體。
- 會啟動行程的驗證工具，關行程前要先證明那是自己開的。重開機後，紀錄的 PID 不算證明；要一起記啟動時間與指令列。
- 以上每一條都是獨立審查者或重跑抓到的，不是寫程式的那個 session 自己發現的。
- 證據段裡，同一分支新增後又修改的測試會列在獨立標題下，不再算成「既有測試」。

## 授權
MIT。靈感來自 Lydia Hallie 與 Lauren Tan 的公開演講，部分 skill 步驟改寫自 Lauren Tan 以 MIT 授權釋出的 pstack；與兩位及其公司無關，也未經其背書。見 [CREDITS](CREDITS.md)。
