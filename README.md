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
| 系統雜物 | `@eaDir`、`#recycle`、`.DS_Store`、`Thumbs.db`… 等（Synology 預設） |

`[File] black_ext` 另排除編譯產物副檔名：`pyc`、`pyo`（以及 `tmp`/`swp`/`lnk`… 等）。

> **不排除**：`.claude`（要跨機器共用 skills）、`data`、`docs` 等實際工作內容——這些是要同步的資料。
> 若某個專案剛好有名為 `build` / `dist` / `coverage` 的**原始碼**資料夾（少見），把該項從清單移除即可。

## 設定步驟

把本專案的 `blacklist.filter` 覆蓋到本機 Synology Drive 的 session 設定檔，**每台電腦各做一次**：

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
> * 若之後在應用程式介面重新設定同步規則，可能會覆蓋此手動修改——屆時再覆蓋一次即可。
> * 修改前建議先備份原本的 `blacklist.filter`。

---

再次感謝原作者的分享與創意！
