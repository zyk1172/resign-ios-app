# 更新记录

## 1.6.0（2026-08-30）

- **增量构建缓存（免重复编译）**：
  - 构建工作区（DerivedData）从 /tmp 迁移到 `Application Support/Resign/DerivedData/<项目UUID>` 并**默认保留**，重启不再丢失，Xcode 增量编译生效——源码未变化时编译阶段被完全跳过（实测 21 文件工程：冷构建 12.7s → 未变化 3.1s，约 **75%** 节省；越大越明显）；
  - 每次构建前仅清空本配置的**产物目录（.app）**，强制 xcodebuild 重跑签名阶段——免费签名 7 天有效期照常刷新（直接重装旧签名 .app 不会刷新 profile，因此不做产物级复用）；
  - `ProjectFingerprintService` 计算项目指纹（工程配置 + 源码/资源/依赖清单内容哈希；排除 .git/build/DerivedData/xcuserdata 等），`BuildCacheManager` 保存每项目元数据并给出带原因的缓存决策，日志输出 `=== CACHE ===` 段；
  - 失效条件：源码/资源/工程文件变化、依赖清单（Package.resolved 等）变化、Scheme/Configuration/平台/Team 变化、项目路径变化、Xcode 版本变化、工作区缺失；工作区损坏（特征错误如 no such module）自动**回退 clean build** 一次；
  - 每次安装日志输出嵌入 profile 的**签名有效期**（"签名有效期至: …"），续签是否刷新直接可查；
  - 项目设置新增「清除构建缓存」按钮（构建进行中拒绝执行；只删除 Resign 管理路径）；
  - 日志/明细显示构建方式徽章：完整构建 / 增量构建。
- 评审遗留修复：Worker 落盘失败时通知不再显示"全部成功"（通知优先级：保存失败 > 执行失败 > 成功）；`installedAppPath` 重命名为更准确的 `builtAppPath`（旧字段解码兼容）；`ProjectPreview` 用 projectID 做 SwiftUI identity（支持同名项目）。
- 调度页新增**「执行明细」面板**，用于核实定时任务：
  - **下次定时检查将执行**：每个启用项目的到期状态徽章（首次执行/已到期/未到期）、安装目标（自动选第一台 / 指定设备名列表 / 本机 /Applications）与上次成功时间；
  - **最近定时执行记录**：时间、项目、状态、安装的 App 产物名、逐设备结果胶囊（✓/✗，重试次数 ×N）；
  - 数据来源为新的结构化日志字段（`installedAppPath`、`deviceInstallSummaries`，含设备名/UDID/成败/尝试次数），不再需要人工翻日志原文；旧版日志自动回退显示失败设备并标注"明细未记录"；
  - 字段全部 `decodeIfPresent`，旧 config.json 向前兼容。

## 1.5.1（2026-08-30）

审查修复（架构评审后补齐的可靠性缺口）：

- **Worker 不再静默失败**：config.json 读取失败时以 exit 3 中止（旧版会当作空配置 exit 0，launchd 记为成功，用户误以为后台续签正常）；执行结果无法落盘时以 exit 4 报告。退出码语义：0 正常 / 1 构建·安装失败 / 2 无效调用 / 3 配置无效 / 4 落盘失败；
- **配置写入失败全链路传播**：`ConfigStore` 的写入错误不再被吞掉——拿到锁 ≠ 写入成功，磁盘满/权限异常时 Worker 与 GUI 均能感知；v1→v2 迁移改为"写入成功后才删除旧 epoch 文件"，写失败不会丢迁移依据；
- **首次失败即记录失败摘要**：`ProjectExecutionState.lastFailureSummary` 在新建执行状态时同样写入，不再等第二次失败；
- **macOS 安装器进程识别修正**：改读 Info.plist 的 `CFBundleExecutable`/`CFBundleIdentifier`（.app 文件名 ≠ 进程名），优雅退出按 bundle id 精确寻址；TERM 后再次校验，应用拒绝退出则中止安装并保留现有版本，绝不替换还在运行的应用；
- 显式补充 v1 配置前向兼容测试（无 `platform`/`schemaVersion`/`executionStates` 的旧 JSON 解码回落默认值）；
- 新增 GitHub Actions CI（macOS runner 跑 xcodegen + 全量单测）与 main 分支保护规则。

## 1.5.0（2026-08-30）

架构级重构：**消除双执行引擎**，统一为一份 Swift 构建核心。

### 双执行引擎移除（P0）
- 新增 `ResignWorker` 可执行 target（嵌入 `Resign.app/Contents/MacOS/`），后台定时任务改为 `launchd` 直接运行 `ResignWorker --scheduled-run`；
- 删除动态生成的 `resign_all.sh` Bash 引擎（约 250 行重复的设备检测/到期判断/构建/产物解析/安装/重试逻辑），`LaunchAgent` 只负责"何时触发"；
- GUI 与后台任务现在调用**同一个** `BuildCoordinator`：设备选择、`-showBuildSettings` 产物定位、xcodebuild 参数、错误分类、重试策略完全一致；同一错误在前后台得到相同判断，同一项目在前后台得到相同 App 产物。

### 跨进程锁闭环（P0）
- 旧版只有 GUI 获取 `resign.lock`，后台 Bash 直接 `rm -rf` DerivedData，仍可能踩踏；现在后台 Worker 与 GUI 都经过 `BuildCoordinator` 内的同一把 flock，被占用时返回明确可记录的失败结果。

### 统一行为
- 设备发现统一为 `devicectl --json-output` 结构化解析，移除后台对人类可读表格的 grep 解析；
- 多设备安装按设备独立追踪：已成功设备不再重装，每轮只重试失败设备；fatal 设备立即停止；
- 重试策略统一：retryable 才重试；fatal / unknown 一律不重试（构建与安装同一 `RetryPolicy`）。

### 单一事实源
- 新增 `ProjectExecutionState`（上次尝试/上次成功安装时间/状态/来源/失败摘要），`config.json` 成为唯一事实源；后台成功会即时更新状态，手动成功同样推进后台到期时间；
- 到期判断统一走 `ScheduleDuePolicy`（本地日历天 + `lastSuccessfulInstallDate`），旧 `logs/state/<uuid>.epoch` 文件迁移一次后废弃；
- `config.json` 增加 `schemaVersion`（v1 自动迁移：超长内联日志落盘、epoch 折叠进执行状态），所有持久化类型使用 `decodeIfPresent`，未来新增字段不会导致旧配置整体解码失败；
- GUI 保存与 Worker 写入通过 `config.lock` flock 做原子读改写合并，互相不覆盖（修复旧版 5 秒 throttle 静默丢弃调度同步的问题——LaunchAgent 不再内嵌项目快照，该同步需求本身消失）。

### 日志系统
- 定时任务日志导入同样走 64KB 落盘阈值（修复后台运行日志把 config.json 撑到几十 MB 的问题）；存量超限日志在迁移时一次性外置；
- `trim` 同时删除被裁剪条目的磁盘文件；"清空日志"同时清理 `logs/` 下全部受管产物（不触碰 config 与调度状态）；启动时清理孤儿日志文件；
- 日志条目区分"手动/定时"来源，日志详情统一经 LogRepository 读取。

### 其他
- AppStore 瘦身：持久化交给 `ConfigStore`、日志交给 `LogRepository`、调度交给 `ScheduleManager`、构建交给 `BuildCoordinator`；View 不再直接访问大型基础设施服务；
- 文件夹扫描改为一次性批量插入 + 单次保存 + 有界并发的 Scheme 发现（最多 3 个 xcodebuild 并行），不再逐项目保存/同步；
- 配置编解码与 launchctl 调用移出主线程；
- 测试从"断言 Bash 脚本文本"迁移为针对 Swift 逻辑的单元测试（70 个）：ProductResolver / FailureClassifier / RetryPolicy / 设备选择与解析 / 到期策略 / 配置迁移与合并 / 执行状态 / BuildCoordinator（注入 MockProcessRunner）/ 调度 plist / 文件锁。

## 1.4.1（2026-08-15）

- 日志落盘：超过 64KB 的构建日志写入 `logs/build_*.log` 独立文件，`config.json` 只保留头部+尾部摘要（保留尾部是为了错误诊断），避免配置被日志撑到几十 MB；日志详情页会自动读取完整文件。
- 定时任务改为**逐项目到期判断**：每个项目独立记录上次全部成功的时间（`logs/state/<项目UUID>.epoch`），只有到期的项目才重新构建安装；某个项目失败不会导致其他健康项目被反复重签。

## 1.4.0（2026-08-15）
（2026-08-15）

- 修复后台定时任务的设备自动识别：现在同时支持现代 UDID（`00008140-000A6D6A2143801C`，8-16）与旧式 8-4-4-4-12 格式，避免"自动选择设备"在 LaunchAgent 后台运行时误判为无设备。
- 定时任务配置不再陈旧：`needsUpdate` 现在逐字节对比已安装脚本与当前项目/设置生成的脚本，并会在修改项目或设置后自动重新生成后台脚本（Team、设备、Scheme、Xcode 路径、重试参数等变化立即生效）。
- 后台脚本定位主 App 产物时按 Scheme/项目名匹配，不再默认取 `-showBuildSettings` 的第 0 个 target，多 Target（Widget/Extension）项目前后台行为一致。
- 构建阶段只对明确判断为临时性的错误重试；编译/链接/无法识别的错误立即停止，不再白白等待数十分钟。
- 命令执行分离 stdout / stderr：`-showBuildSettings -json`、`-list -json` 等只解析 stdout，避免 Xcode 的 warning/note 污染 JSON。
- 新增跨进程任务锁（`resign.lock`），防止后台 LaunchAgent 与手动执行同时清空同一个 DerivedData 目录互相踩踏。
- 错误诊断补充：开发者模式未开启、证书过期、Xcode 许可未接受、磁盘空间不足；并修正"App 扩展占名额"的表述为更严谨的说法。

## 1.3.0（2026-08-08）
（2026-08-08）

- 智能识别"确定性"安装/签名错误（设备不在当前 Team 的测试设备列表、免费签名配额已满、Bundle ID 已被其他账号注册、Team 未登录 Xcode 等），遇到这类错误立即停止，不再盲目等待数十分钟到数小时的重试；
- 日志页对上述错误显示可直接照做中文诊断（如"请在 Xcode 中连接该设备并选它运行一次"、"每台设备免费最多 3 个 App"）；
- 定时任务脚本同步升级（schedule v6）：后台自动任务遇到同样错误时也不再循环重试，避免任务"卡住"数小时。

## 1.2.0（2026-08-07）
（2026-08-07）

- 为每个项目新增"开发者 Team"选择：从钥匙串中的开发者签名证书自动识别可用 Team，构建和定时任务通过 `DEVELOPMENT_TEAM` 指定 Team 进行自动签名。

## 1.1.1（2026-07-29）

- 启动时同时校验定时脚本和 LaunchAgent plist，自动迁移被旧版本覆盖的 `StartInterval` 任务；
- 校验计划时间、脚本路径和 `RunAtLoad`，避免“已装载”掩盖过期配置；
- 修复旧 Xcode 调试副本覆盖任务后，退出正式 App 无法按计划后台执行的问题。
- 按本地日历天而非精确秒数判断执行间隔，避免“6 天”因每日检查时刻提前而延后到第 7 天。

## 1.1.0（2026-07-26）

- 使用 Xcode 自动签名，从源码重新构建并安装 iOS App；
- 支持多个项目、Scheme、构建配置和实体设备；
- 增加手动执行、每日检查、按间隔执行、取消、重试与日志；
- 使用 `devicectl` 安装，并准确定位主 App 构建产物；
- 加固命令执行、临时目录清理、LaunchAgent 状态检查和本地数据保护；
- 新增 Apple 芯片与 Intel 通用构建，以及可复现的 DMG 打包、挂载验证和 SHA-256 校验流程。
