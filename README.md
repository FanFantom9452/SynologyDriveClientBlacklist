# SynologyDriveClientBlacklist

此專案記錄如何透過手動編輯 Synology Drive Client 的 `blacklist.filter` 設定檔來排除特定資料夾，
例如 `.git` 或 `node_modules`。

感謝原作者的分享與教學，原文由 **LosEcher** 發表在 [Gist](https://gist.github.com/LosEcher/8b204e78d372b4441b488bd0176488f1)，
without whom this guide would not exist. 🙏

## 設定步驟

只要把專案中的 `blacklist.filter` 檔案直接覆蓋到以下路徑即可：

Windows:

```
C:\Users\<User>\AppData\Local\SynologyDrive\data\session\<session_id>\conf\blacklist.filter
```

macOS:

```
~/Library/Application Support/SynologyDrive/data/session/<session_id>/conf\blacklist.filter
```

覆蓋後的檔案已經包含了想排除的資料夾設定，例如：

```ini
[Directory]
black_name = ".git"
```

Synology Drive Client 會在底層設定層面忽略這些資料夾。

> ⚠️ 注意事項
>
> * 這是手動編輯設定檔的方法，非官方 GUI 操作。
> * 若在應用程式介面重新設定同步，可能會覆蓋手動修改。

---

再次感謝原作者的分享與創意！
