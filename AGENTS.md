# AGENTS.md

## Xcode / Apple Platform Development

### 工具链（本机真实配置，2026-08-15 检测）
- 推荐 Xcode: **Xcode 27.0 Beta**（Build 27A5209h），路径 `/Applications/Xcode-beta.app`
- Developer Directory: `/Applications/Xcode-beta.app/Contents/Developer`
- 本机**没有正式版 Xcode**，系统 `xcode-select` 仍指向 CommandLineTools。
- 任何 `xcodebuild` / `xcrun` / `swift` / `simctl` 命令前必须设置:
  ```bash
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  ```
  或直接使用 `scripts/xcode-beta.sh` / `scripts/build-macos-app.sh` / `scripts/test-macos-app.sh`。
- 不要修改 Xcode 隐藏 `defaults`，不要为了“优化”乱动 Build Settings。

### 项目结构
- 项目: `Resign.xcodeproj`（由 **XcodeGen** 生成，源文件是 `project.yml`）
- 修改 `project.yml` 后必须运行: `xcodegen generate`
- 主 Scheme: `Resign`（已共享到 `xcshareddata/xcschemes/`）
- App Target: `Resign`（macOS app，Deployment Target macOS 14.0，Swift 5.9）
- Test Target: `ResignTests`（XCTest，位于 `Tests/ResignTests`）
- SPM: 本项目不使用 Swift Package / CocoaPods，无 `Package.resolved`。

### 常用命令
```bash
export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"

# Release 通用包（现有脚本，x86_64+arm64，含签名校验）
./scripts/build-macos-app.sh

# Debug 构建 + 单元测试（推荐日常验证）
./scripts/test-macos-app.sh

# 等价的手工命令
xcodebuild -project Resign.xcodeproj -scheme Resign -configuration Debug -destination 'platform=macOS' build
xcodebuild -project Resign.xcodeproj -scheme Resign -configuration Debug -destination 'platform=macOS' test
```
- DerivedData: 保留默认，增量构建缓存不清除；仅缓存损坏等明确原因才针对性清理当前项目 DerivedData。
- 测试优先 `build-for-testing` + `test-without-building` 减少重复编译。

### 签名
- `CODE_SIGN_STYLE = Automatic`，`CODE_SIGN_IDENTITY = "-"`（本地 ad-hoc），本地 Build 不需要 Team。
- 真机/分发打包时才需要签名环境；不要为了命令行 Build 成功而改动
  Bundle ID（`com.resign.app`）、Team、Entitlements 或 Capabilities。

### 修改后验证标准（必须遵守）
修改 Swift / SwiftUI / Objective-C 代码或 Xcode 项目后，环境允许时必须至少运行一次:
1. **Build**（每次修改后必须）
2. 涉及业务逻辑 → **Unit Test**（本项目的 `ResignTests`）
3. 涉及 UI / Navigation / Sheet / Window / Scene / State / Persistence / Networking / Concurrency → Build + 相关测试

测试失败时:
- 找到**第一个真正失败的错误**（后续几十个错误可能只是级联错误），不要只报告 `tests failed`。
- 先诊断再修复，修复后重新 Build/Test。

### 禁止事项
- 不使用来源不明的 Xcode hidden `defaults` 做“性能优化”
- 不批量关闭 compiler warnings
- 不永久关闭代码签名
- 不删除全部 Simulator / Device Support / Package.resolved
- 不自动升级所有依赖
- 不修改 Deployment Target / Bundle ID 来逃避编译或签名错误
- 不把 Debug 当 Release（或反之）
- 不关闭安全检查只为通过 Build
