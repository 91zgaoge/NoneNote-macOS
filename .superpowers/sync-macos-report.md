# NoneNote macOS 同步实施报告

日期：2026-08-31 ・ 目标项目：/Users/yuzaimu/projects/NoneNote-macOS ・ 源项目（只读）：/Users/yuzaimu/noty

## Commits

| hash | 说明 |
|---|---|
| `9c020e7` | chore: fork from noty + rebrand to NoneNote |
| `c31701a` | feat: WebDAV sync |

## 复制与更名（影响面最小方案）

- 复制 `noty/` 全部内容，排除 `.git/ build/ demo.gif media/ screenshots/ site/`（rsync），`git init -b main`。
- **保留**：app 目录名 `Noty.app`、可执行名 `Noty`（`CFBundleExecutable`）、数据库目录 `~/Library/Application Support/Noty/`（继承用户已有数据，`Paths` 与 `build.sh` 零改动）。进程名仍为 `Noty`。
- **改动**：
  - `Info.plist`：`CFBundleName`/`CFBundleDisplayName` → `NoneNote`；`CFBundleIdentifier` → `com.noty.macos`（按设计文档）；`NSHumanReadableCopyright` 文案更新；Sparkle 注释改为说明其在本 fork 中为惰性（无 Sparkle framework，`Updater.swift` 编译成 stub，不会发请求；`SUFeedURL` 等键保留未删）。
  - 用户可见文案：`AppDelegate.swift`（About 标题/正文——正文最后一段改为说明可选 WebDAV 同步；菜单 "About/Hide/Quit NoneNote"）、`NoteStore.swift`（欢迎便签 "Welcome to NoneNote"）、`DeckController.swift`（右键菜单 "Quit NoneNote"）、`SettingsWindow.swift`（窗口标题 "NoneNote Settings"）、`LibraryWindow.swift`（窗口标题）、`ExportImport.swift`（导出文件名前缀 `NoneNote-`、单文件导出标题、`.stickies` 归档 `app` 字段）。
  - 内部标识未动：`enum NotyMain`、`NSLog("Noty: …")` 日志前缀、`README.md` 仍为上游内容。

## WebDAV 同步

协议逐字按设计文档：`{root}/NoneNote/sync.json` 全量快照 + 墓碑；`app="NoneNote" version=1`；Basic auth；PROPFIND 探测 / MKCOL 建目录 / GET 拉 / PUT 推；凭据只存 UserDefaults，源码无硬编码。

- `Sources/SyncMerge.swift`（仅 Foundation，可脱离 AppKit 编译）：
  - `SyncNote`（字段与 `Note` 一一对应的值类型）、`SyncTombstone`、`SyncSnapshot`、`MergeResult`。
  - `SyncJSON`：ISO8601 编解码；写带小数秒（保住亚秒级 modified 次序），读兼容整秒（其他平台）。
  - `SyncMerge.merge(local:tombstones:remote:)`：按 id 并集，同 id 取 `modified` 大者、**相等取远端**；墓碑 `deletedAt > modified` 删除该 note；note 存活（`modified >= deletedAt`）的墓碑被裁剪；输出按 `(order, id)` 排序保证推送载荷稳定（供 hash 防回环）。
  - `SyncMerge.detectDeletions(knownIds:currentIds:at:)`：上次同步 id 集 − 当前 id 集 → 本地删除墓碑。
- `Sources/WebDAVSync.swift`：
  - `SyncNote ↔ Note` 转换（extension）。
  - `WebDAVConfig`：UserDefaults 键 `webdavURL/webdavUser/webdavPass` + 内部状态 `syncKnownIds`（JSON id 数组）、`syncDeleted`（JSON 墓碑）、`syncPushedHash`、`syncLastAt`。
  - `WebDAVClient`：URLSession async/await，手动 `Authorization: Basic` 头，20 s 超时；`probe()`（PROPFIND 文件，404 时 MKCOL `NoneNote/`）、`pull()`（GET，404 → nil）、`push()`（PUT）。
  - `SyncManager`（singleton, ObservableObject）：`start()` 挂 `NoteStore.$notes` 的 2 秒 debounce 并立即同步一次；`syncNow()` 串行化（进行中置 `runAgain`）；流程 = 本地快照 → 墓碑检测 → probe/pull → `SyncMerge.merge` → 主线程 `NoteStore.applyMerged` → 内容 hash（SHA256，**不含 `updated`**，因 updated 每次取当前时间）≠ `pushedHash` 才 PUT → 落盘 knownIds/墓碑/lastSyncAt。所有错误仅 `NSLog`，不弹窗不崩溃。
  - 防回环双保险：`applyingRemote` 标志在 apply 期间屏蔽 debounce 触发；`syncPushedHash` 使内容没变时跳过 PUT。
- 既有文件的最小接线：
  - `NoteStore.applyMerged(_:)`：整体替换 notes（保留现存相对顺序），清 undo toast，`store.replaceAll`。
  - `Store.replaceAll(_:)`：BEGIN/DELETE/逐条 upsert/COMMIT 单事务。
  - `AppDelegate`：启动时 `SyncManager.shared.start()`；新增 `@objc syncNow()`。
  - `DeckController` 右键菜单：Settings… 上方加 "Sync Now"。
  - `SettingsWindow`：新增 "Sync" 区（Server URL / Account / Password(SecureField) / Sync Now 按钮 / Last sync 时间），配置即存 UserDefaults。

## 验证

- 合并测试（`swiftc Tests/sync_merge_test.swift Sources/SyncMerge.swift -o /tmp/merge_test && /tmp/merge_test`）：**15/15 通过**。覆盖 JSON 往返、schema 字段、整秒 ISO8601 兼容、LWW 双向、相等取远端、并集、本地/远端墓碑删除、过期墓碑裁剪、墓碑并集取 max deletedAt、本地删除检测、合并幂等。
- `./build.sh`（release）：成功，签名有效，产出 `build/Noty.app`；`./build.sh debug`：成功。仅有 Sendable 警告（swift-version 5，不影响）。
- curl 冒烟（测试服务器 http://10.40.31.69:7099）：

```
PROPFIND /NoneNote/sync.json        → 404
MKCOL    /NoneNote/                 → 201
PUT      /NoneNote/sync.json        → 201
GET      /NoneNote/sync.json        → 200，内容与 PUT 完全一致
DELETE   /NoneNote/sync.json        → 204（清理）
```

客户端 `probe()` 的 404 → MKCOL → GET → PUT 流程与上述手工序列一一对应。

## 疑虑 / 未做

- 未实机运行 .app（避免在用户机器上弹出 accessory 应用）；UI 行为（设置区、右键菜单）只验证到编译期。
- Undo 删除的边界：若删除已同步（产生墓碑）后再 undo 恢复，因恢复的 note 保持旧 `modified < deletedAt`，下次合并会再次删除它（符合 LWW 语义，Android 侧同）。10 秒 undo 窗口内通常还未同步，实际影响小。
- `Info.plist` 保留指向上游 noty 的 `SUFeedURL`（无 Sparkle 时惰性，不会发请求）；将来若引入 Sparkle 需先换掉。
- 数据目录沿用 `~/Library/Application Support/Noty/`：这是与旧 noty 数据兼容的取舍，若后续想彻底改名需加迁移。
