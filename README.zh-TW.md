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
| `hooks/subagent-verify.sh` | 第 2 層，同時註冊為 `SubagentHandback` 的 PreToolUse hook 和 `SubagentStop` hook。子代理要交報告前（沒有那個工具的環境則是要停下前），從它自己的對話紀錄判斷有沒有改到受信任的 checkout，有就跑該專案的檢查。失敗就擋下（`exit 2`），子代理繼續修。每個子代理最多擋 2 次，同一個確切狀態只擋一次。結束時會逐一比對 checkout。最近一次交報告時已通過或已被擋下、且狀態相同的 checkout 會跳過（帳本記 `handback-done`）。先前失敗或未完成的檢查仍會顯示原因。 |
| `tools/codex-dispatch.sh` | 只接受白名單參數的 `codex exec` 包裝：唯讀或可寫工作區、預設斷網（指 Codex 執行的指令；prompt 與圖片仍會送到模型服務；呼叫者可加 `--net`）、不載入使用者設定、可寫模式只能改目前所在的 repo（或你列出的 repo）、報告只能寫到 `<repo>/.scratch/` 或 `/tmp`。 |
| `tools/verify-evidence.sh` | 跑檢查並產生綁 commit 的證據段：SHA、指令、結束碼、log 雜湊、它在 `PATH` 上找到的 `node` 與 `python3`（`--tool <名稱>` 可加列；路徑會遮罩，貼出前仍請看過那一行）、有沒有改到既有測試。同一分支新增後又修改的測試列在獨立標題下。腳本不改 `PATH`：工具那一行出現 shim 或舊版直譯器，就修好 `PATH` 再重跑。工作區不乾淨就拒跑；中途有變動或無法檢查測試改動時結束碼 90（INVALID）。預設不印 log 內容，要附 log 尾段用 `--tail N`；但會印出完整指令，密碼請用環境變數傳，貼到公開 PR 前先看過整段。指令若改檔再改回，本機證據看不出來；真正的關卡是 CI 在乾淨 checkout 上重跑。 |
| `docs/METHOD.zh-TW.md` | 一頁說完方法。 |

安裝：外掛會註冊停止 hook 與新的兩個 hook，專案登記前它們都什麼都不做。設定步驟請看 [README.md](README.md)（指令相同）。專案登記的 key 是 `owner/repo`，例如 `alice/shop`；另外必須填 `roots`：你信任的 checkout 絕對路徑。其他位置的 clone（就算同一個 repo）都不會被執行，hook 會提示並印出該補進 `roots` 的實際路徑。信任的 checkout 底下的 linked worktree 也算信任。選填 `skip_re`：符合的檔案不會觸發檢查（自動產生的檔案、被中斷的測試留下的資料夾）。每次判定都會追加一行到 `~/.claude/state/stop-verify/ledger.tsv`（只在本機、不印出、不含完整路徑）。有子代理、workflow 或 `codex-dispatch.sh` 在跑時會先不檢查，等下一次收工再跑。`STOP_VERIFY_DEADLINE`（120..540 秒，預設 540）是總時間上限。要強制重跑已失敗的狀態：改一個檔案，或刪掉 `<state 資料夾>/<id>.red`。`VERIFY_CHANGED_FILE` 以換行分隔，所以不支援含換行的檔名。登記前先請 AI 跑 `/verify-loop setup`，它會讀測試設定，列出會重置資料庫、部署、寄信或打付費 API 的步驟。

更新既有安裝時，依序執行 `claude plugin marketplace update verify-loop`、`claude plugin update verify-loop@verify-loop`，再重新啟動 Claude Code。0.1.1 的 hook 指令與證據工具的單一字串指令會啟用 Bash `pipefail`，因此 `test-command | tee log` 會保留測試失敗的結束碼。把程式名稱和參數分開傳給證據工具，即可直接執行程式。`head` 或 `grep -q` 可能提前關閉管線，讓上游指令以 141（SIGPIPE）結束。驗證指令可先把完整輸出寫入檔案再搜尋。主 Stop 遇到非零結束碼會擋下，改檔與子代理 hook 遇到訊號則回報未驗證。

### 每次改檔後的快速檢查，與子代理交報告前的檢查

兩個 hook 讀同一份專案檔、用同樣的 `roots` 信任方式。它們是選擇加入的：專案沒填 `edit_check`，第 1 層就不碰它；沒填 `handback_verify`，第 2 層就不碰它（不會拿停止 hook 的 `verify` 來跑）。兩個 hook 都以你的身分、在 Claude Code 沙盒外執行你的指令，而且時機是停止 hook 沒有的：第 1 層在每次符合的改檔後，第 2 層在改過 checkout 的子代理交報告時。這兩個 hook 只有在 `$STOP_VERIFY_CONFIG` 是指向一般檔案（不是連結）的絕對路徑，而且位於 `~/.claude` 或 `~/.config` 底下時才採用；否則用 `~/.claude/stop-verify.projects.json`。停止 hook 仍接受任何絕對路徑。

```json
{
  "your-name/my-web-app": {
    "roots": ["/home/you/src/my-web-app"],
    "verify": "npx tsc --noEmit && npm test --silent",
    "edit_check": {
      "files_re": "^(src|server)/.*\\.(ts|tsx)$",
      "cmd": "npx tsc --noEmit --pretty false",
      "limit": 15
    },
    "handback_verify": "npx tsc --noEmit && npm test --silent",
    "handback_limit": 420
  }
}
```

- `edit_check`（第 1 層）：`files_re` 是對「相對 repo 根目錄的路徑」的擴充正規式；`cmd` 是在 repo 根目錄跑的 bash 指令，`$EDIT_FILE` 就是那個路徑；`limit` 單位秒（1..15，預設 15）。只有 `cmd` 結束碼非 0、而且輸出有一行點名剛改的檔（整段路徑，相對或絕對都行）才擋，最多顯示 20 行。`cmd` 只報別的檔，這次編輯就放行。請讓工具印出相對 repo 根目錄的路徑。比對前會去掉 ANSI 色碼，並設 `NO_COLOR=1`。設了 `requires` 而路徑不存在時，檢查會跳過。比對只看「輸出裡有沒有一行提到這個檔」，不解析診斷格式，所以一行提到該檔的狀態訊息，加上另一個檔的錯誤，仍可能擋下。
- `handback_verify`（第 2 層）：改過這個 checkout 的子代理交報告時跑的指令，沒有退回 `verify` 的備援：沒填這個欄位，第 2 層就不碰該專案。結束碼非 0 算失敗；124、126、127 或被訊號殺掉算「沒驗完」，交報告照常通過。`$VERIFY_CHANGED_FILE` 列出子代理用編輯工具寫過的檔。
- `handback_limit`：這次執行的秒數上限，超過算「沒驗完」（1..440，預設 420；hook timeout 是 480）。

帳本：`~/.claude/state/post-edit-check/ledger.tsv` 與 `~/.claude/state/subagent-verify/ledger.tsv`（只在本機、不印出）。

相容性實測包含 Claude Code 2.1.326 與 Codex CLI 0.164.0。Claude Code 2.1.329 另有子代理在結束時被擋、修好、再通過的實跑紀錄。

GitHub Actions 會在每張 PR 及每次推送至 `main` 時，於 Ubuntu 和 macOS 執行 `bash tests/run.sh`。要兩者都通過才可合併，請在分支規則加入 `verify-loop tests` 和 `verify-loop tests (macOS)`。

## 伺服器端硬擋：用 CODEOWNERS 保護測試
本機的測試守衛可以被繞過（先 commit 再改測試），交給 GitHub 擋：把 `examples/CODEOWNERS` 複製到 `.github/CODEOWNERS`，填上測試路徑和負責人，預設分支要求 PR 與 Code Owner 審核（管理員也適用）。AI 必須用另一個帳號 push，因為 GitHub 不准帳號核准自己的 PR。公開 repo 免費；私人 repo 需付費方案。

## 注意
- 停止 hook 用你的帳號權限、在 Claude Code 沙盒外跑測試指令；AI 能改 `package.json` 或測試，hook 之後會照跑。信任是看路徑：在登記的資料夾切到別人的分支或 PR，hook 會用你的權限跑那個分支的測試腳本。外部 PR 請用另一份沒登記的 clone；要隔離就讓 `verify` 自己啟動容器或 VM。
- 停止 hook 不會偵測用 skip-worktree／assume-unchanged 藏起來的檔案；evidence 腳本仍會拒絕這種情況。
- 同一個 checkout 同時收工，可能各自跑檢查、各自被擋；另一個 session 記下的通過，可能蓋過這個 session 先前對同一份程式的失敗。
- 只要登記的 repo 有改動（包括你自己沒做完的），hook 就會觸發。失敗不是這個 session 造成時，Claude 被要求說明並停手，但它仍可能去改。
- 第 1 層（`post-edit-check.sh`）在改檔之後才跑，無法還原那次編輯，只能告訴 Claude。只有點名被改檔案的輸出行才會擋，所以不印路徑的工具永遠不會擋。
- 第 2 層（`subagent-verify.sh`）在環境有 `SubagentHandback` 時，於那個工具呼叫處執行；沒有時改在 `SubagentStop` 執行。兩個事件都有註冊。 Claude Code 在 auto mode 下會將交報告工具提供給本機執行、非 fork 的子代理。[官方工具說明](https://code.claude.com/docs/en/tools-reference#tools) Claude Code 2.1.329 的 session 觀察到沒有 `SubagentHandback`，而 `SubagentStop` 在那裡有效（失敗、修好、通過）。交報告時逾時，若 checkout 沒有改變，結束時會保留「未驗證」。再次交報告可重新執行檢查。子代理自己的對話紀錄裡，交報告工具成功才代表已交付。此後 checkout 有新改動，Stop 會回報未驗證，子代理可以結束。若交付工具失敗，Stop 仍可驗證後續工作。若失敗的測試產生覆蓋率檔，該狀態只沿用先前的失敗提醒。
- 第 2 層面對的是共用的 checkout。失敗可能來自別的 session 的改動，所以擋下時的訊息會這樣說，並要求子代理不要去還原不是自己的改動。
- 第 2 層靠字串比對（`>`、`sed -i`、`mv`、`git checkout` 等）加路徑名稱，找出子代理用 Bash 寫的檔。可能漏掉，也可能把無害的指令算進去。唯讀的 git（`status`、`log`、`diff`、`show`、`stash list`）不算寫入。
- 第 2 層不管子代理改的是哪個檔，都會跑完整的 `handback_verify`。
- Bash 指令裡的 `=` 與 `:` 都算路徑的起點，所以像 `/tmp/archive=<root>/x` 這種奇怪的路徑，仍可能選中受信任的 checkout `<root>`。
- 第 2 層用 git 取得 checkout 的指紋。repo 裡設定的 clean 或 smudge filter，可能在 git 讀檔時執行。
- 舊的封鎖紀錄（`<session>.<agent>.blocked`）30 天後刪除；超過這段時間才續接的子代理，封鎖次數會重新計算。
- 兩個 hook 都是先檢查信任、稍後才啟動指令。若中間有人把 linked worktree 換成 symlink，指令可能在錯的位置執行。這個競態沒有防禦。
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
- 某款遊戲的幫手已經載入，卻可能跑到畫面外或被 HUD 蓋住。操作工具現在檢查玩家看得到幫手，而且幫手確實移動。移除預設幫手時流程報失敗，還原後連跑十次通過。
- 要操作使用者拿到的那個版本。第一版操作工具 build 時沒開正式功能旗標，四條流程是在使用者看不到的畫面上通過的。
- 圖要對得上程式。截圖上的 commit 編號必須就是那個 commit 的 build。那個專案的操作工具把未提交的 build 標成 `+dirty`，並拒絕別的狀態 build 出來的執行個體。
- 會啟動行程的驗證工具，關行程前要先證明那是自己開的。重開機後，紀錄的 PID 不算證明；要一起記啟動時間與指令列。
- 以上每一條都是獨立審查者或重跑抓到的，不是寫程式的那個 session 自己發現的。
- 證據段裡，同一分支新增後又修改的測試會列在獨立標題下，不再算成「既有測試」。

兩個新 hook（改檔後檢查、子代理交報告前檢查）在同一個專案第一天的紀錄（兩份帳本都還很小，只能算早期跡象，不是結論）：

- hook 不能只靠單元測試，要在真的環境跑一次。第 2 層第一版聽的是「子代理結束」事件，212 個單元測試都過。實際使用時記了兩次失敗，卻沒有東西被修：擋下的訊息到的時候，子代理已經交出報告了。改掛在「交報告」這個工具呼叫之前，才跑出一次完整的 失敗 → 修好 → 通過。
- hook 依賴的環境功能可能在版本之間消失：這個 hook 原本依賴的「交報告」工具，在較新的 session 裡不見了；兩個事件都註冊，檢查才繼續有效。
- 時限要用忙碌機器的實測來定。全套測試在機器忙時要 133–226 秒，閒時估計 100–130 秒。第一版時限 200 秒，機器一忙就永遠是「未驗完」。
- 檢查工具沒涵蓋的檔是「跳過」，不是「通過」。那個專案的型別檢查設定只涵蓋兩個資料夾，其他地方的改動被跳過、沒有檢查（當時跑的私人版本把它們記成 `skip`）。
- 大多數子代理不改檔。第 2 層 17 筆紀錄裡有 11 筆是唯讀子代理，檢查對它們沒有成本。
- 改檔後的快速檢查馬上有用：擋下三次，每次都在 4–6 秒後的下一次改檔修好。每次檢查 2–6 秒。目前沒有誤擋。

## 授權
MIT。靈感來自 Lydia Hallie 與 Lauren Tan 的公開演講，部分 skill 步驟改寫自 Lauren Tan 以 MIT 授權釋出的 pstack；與兩位及其公司無關，也未經其背書。見 [CREDITS](CREDITS.md)。
