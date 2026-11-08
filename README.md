# SynologyDriveClientBlacklist

一份版本控管、跨機器共用的 **Synology Drive Client 全域過濾規則**（`blacklist.filter`）。
把它放進 git，每台電腦拉同一份、覆蓋到本機 Synology Drive 設定，就能讓所有機器的同步規則一致。

感謝原作者 **LosEcher** 的分享與教學，方法出處：
[Gist](https://gist.github.com/LosEcher/8b204e78d372b4441b488bd0176488f1) 🙏

## 為什麼要排除這些

檔案同步工具（Synology Drive、Dropbox…）**不該同步兩類東西**：

1. **版本控管的中繼資料**：`.git`
   - `.git/` 是資料庫，假設「單一程序、一次一寫、多檔原子性」。
   - 檔案同步工具是多寫者、逐檔非原子 → 跨機器同步 `.git` 會造成 index／refs／objects 損壞（鎖檔打架、物件遺失、repo 錯亂）。
   - **程式碼要跨機器一致，請用 git 自己的機制（clone / pull / push），不要靠檔案同步工作樹。**

2. **可重生、機器專屬的產物**：套件目錄、虛擬環境、建置輸出、快取
   - `node_modules` / `.venv` / `venv` / `dist` / `build` / 各種 `.*cache` 等。
   - 這些每台機器各自 `npm install` / `pip install` / build 就會重新產生。
   - 同步它們既肥又慢，而且**跨作業系統／路徑會直接壞掉**（例如虛擬環境內含絕對路徑與平台二進位）。

## 目前排除清單（`[Directory] black_name`）

| 類別 | 目錄 |
|---|---|
| 版本控管 | `.git` |
| 套件／相依 | `node_modules`、`.node-gyp` |
| Python 環境／快取 | `.venv`、`venv`、`__pycache__`、`.pytest_cache`、`.ruff_cache`、`.mypy_cache` |
| 建置輸出 | `dist`、`build`、`.next`、`.svelte-kit`、`.turbo`、`.vite`、`.parcel-cache` |
| 工具／IDE／快取 | `.cache`、`.gradle`、`.idea`、`coverage`、`.playwright-mcp` |
| fankeel／git 工作樹 | `.fankeel`、`worktrees`、`.worktrees`、檔案 `.git`（`[File] black_name`） |
| 系統雜物 | `@eaDir`、`#recycle`、`.DS_Store`、`Thumbs.db`… 等（Synology 預設） |

`[File] black_suffix` 另排除編譯產物副檔名：`.pyc`、`.pyo`（以及 `tmp`/`.swp`/`.lnk`… 等）。
`black_ext` 可能是舊鍵，daemon 自己寫出的檔只有 `black_suffix`；本檔保留 `black_ext`，但一律以 `black_suffix` 為準。

> **不排除**：`.claude`（要跨機器共用 skills）、`data`、`docs` 等實際工作內容——這些是要同步的資料。
> 若某個專案剛好有名為 `build` / `dist` / `coverage` 的**原始碼**資料夾（少見），把該項從清單移除即可。

## fankeel 專案與 git 工作樹

**為何排除 `.fankeel`。** fankeel（Claude Code 外掛）在每個專案的 `.fankeel/` 存狀態：`sessions/*.json` 每次對話都以「寫暫存檔再改名」重寫，`build/`、`station/`、`tmp/`、`worktrees/` 都可重生且可能很大。這些檔含絕對路徑；兩台機器各寫一份會互相覆蓋，Synology 的衝突副本還會被 fankeel 讀成假任務。所以 `.fankeel` 整個不同步，狀態改由 `migrate.js pack` 打成一個 ZIP 傳遞，另一台用 `migrate.js unpack` 拆開。程式碼仍走 git push／pull。

**為何排除 `worktrees`、`.worktrees` 與檔案 `.git`。** `git worktree add` 建立的工作樹，頂端的 `.git` 是一個**檔案**，內容是 `gitdir: F:/.../.git/worktrees/<id>` 這種絕對路徑，到別台機器必壞。`[Directory] black_name` 的 `.git` 擋不到檔案，所以另有 `[File] black_name = ".git"`，並排除工作樹常住的目錄（`.fankeel/worktrees/`、`.claude/worktrees/`、`.worktrees/`）。

**ZIP 放哪裡。** 路徑由你用 `migrate.js pack --to <路徑>` 自選：

- 有 NAS：建議放同步根目錄下的 `_fankeel-migrate/<專案名>/`，由 Synology Drive 運送。
- 沒有 NAS：隨身碟、雲端硬碟資料夾，或任何能帶到另一台的地方都行。
- **不可放在 `.fankeel` 裡**，否則不會被同步。

ZIP 先寫成 `.zip.tmp`，寫完才改名；`tmp` 結尾的檔不同步，所以半寫的 ZIP 永遠不會上傳。

**使用規則：同一個被同步的專案資料夾，一次只在一台機器上工作，換機用 pack／unpack。** 兩台各有自己的 `.git`，而工作樹檔案仍會同步，所以 B 機的 `git checkout` 會透過同步改寫 A 機的工作樹。

## 規則工具（Windows）

不需要安裝任何東西。在 repo 資料夾雙擊 `start.cmd`，或在 PowerShell 執行（`<tag>` 換成發佈的版本）：

```powershell
irm https://raw.githubusercontent.com/FanFantom9452/SynologyDriveClientBlacklist/<tag>/run.ps1 | iex
```

工具會在 `127.0.0.1` 啟動本機 server 並打開瀏覽器，可切換繁中／英文。在網頁上選擇 session 與規則組、預覽變動，再備份並套用；需要時也能還原備份。按「完成並關閉」後 server 就會停止。

- 預設是合併：只新增勾選的規則，不動你原本的規則。「完全覆蓋」會換成內建的 `blacklist.filter`。
- 工具不會強制結束 Synology Drive，套用前會請你從系統匣結束，偵測到關閉才繼續。
- 同步資料夾只在 log 能明確判斷時顯示，否則標示未知，不影響套用。
- `[File] black_name` 尚未確認會被 daemon 保留，所以「Git 工作樹的 .git 檔案」預設不勾選。

開發：程式碼在 `src/`（Domain、Application、Infrastructure、Presentation），修改後執行 `build.ps1` 重新產生 `run.ps1`，用 `tests\Run-Tests.ps1` 測試。

## 設定步驟

把本專案的 `blacklist.filter` 覆蓋到本機 Synology Drive 的 session 設定檔，**每台電腦各做一次**。session 目錄可能不只一個（例如 `1`、`2`），每個 `data\session\<n>\conf\blacklist.filter` 都要覆蓋。

覆蓋前請先從系統匣結束 Synology Drive Client，確認三個 `cloud-drive-*` 程序都消失，並先備份原本的規則檔。不要用工作管理員或 `Stop-Process` 強制結束；實測強制結束後 daemon 曾無法啟動。

手動操作的路徑：

Windows：

```
C:\Users\<User>\AppData\Local\SynologyDrive\data\session\<session_id>\conf\blacklist.filter
```

macOS：

```
~/Library/Application Support/SynologyDrive/data/session/<session_id>/conf/blacklist.filter
```

覆蓋後**重啟 Synology Drive Client**（或重新啟用同步）讓規則生效。

> ⚠️ 注意
>
> * 這是手動編輯設定檔的方法，非官方 GUI 操作。
> * 之後若在應用程式介面改過同步規則，`[Directory]` 段會被丟掉——屆時要重新套用一次。
> * 修改前建議先備份原本的 `blacklist.filter`。

---

再次感謝原作者的分享與創意！
