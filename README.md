# Resign

Resign 是一个原生 macOS 工具，用于定期重新构建你拥有源码的 iOS 项目，使用 Xcode 自动签名，并把新构建的 App 安装到已配对的实体 iPhone 或 iPad。

它主要解决个人开发者签名有效期较短时，需要重复打开 Xcode、构建和安装的问题。

## 适用范围

Resign 适合以下场景：

- 你拥有 iOS App 的源代码和合法使用权；
- 项目可以通过 `.xcodeproj` 或 `.xcworkspace` 构建；
- Xcode 已登录可用的 Apple Developer 账号，项目支持自动签名；
- 目标设备已与 Mac 配对，可通过 USB 或本地网络连接；
- 希望手动或定期重新构建并安装 Debug/Release App。

Resign **不适用于**：

- 对下载的第三方、App Store 或加密 IPA 进行破解、脱壳或绕过 DRM；
- 没有源代码的 IPA/App 通用重签名；
- 绕过证书撤销、设备限制、企业策略或 Apple 平台安全机制；
- 无人登录时运行。定时功能使用当前用户的 LaunchAgent；
- 替代 Xcode、开发者账号、签名证书或 Provisioning Profile。

## 主要功能

- 扫描并管理多个 Xcode 项目；
- 为每个项目单独选择开发者的 Team（自动签名，`DEVELOPMENT_TEAM`）；
- 自动读取共享 Scheme；
- 检测已配对的实体 iOS/iPadOS 设备；
- 使用独立 DerivedData 目录重新构建每个项目；
- 从 Xcode 构建设置中准确定位主 App，避免安装旧产物或扩展；
- 通过 `xcrun devicectl` 安装到一个或多个设备；
- 支持取消、临时错误重试、防止构建期间睡眠和完成通知；
- 智能区分"临时故障"与"确定性错误"：设备不在当前 Team 测试列表、免费签名配额已满、Bundle ID 已被其他账号注册、Team 未登录 Xcode 等错误会立即停止并给出可操作的中文诊断，不会盲目等待数十分钟到数小时的重试；
- 在指定时间每天检查，达到设定间隔后执行自动任务；
- 将手动和后台任务日志统一显示在 App 中。

## 系统要求

- macOS 14 或更高版本；
- Apple 芯片或 Intel 处理器；
- 完整安装的 Xcode，且包含 `xcodebuild` 和 `devicectl`；
- Xcode 中已经登录 Apple Developer 账号；
- iPhone/iPad 已信任并与当前 Mac 配对。

项目构建脚本会自动尝试 `/Applications/Xcode.app` 和 `/Applications/Xcode-beta.app`，也可以通过 `XCODE_PATH` 指定其他位置。

## 使用方法

1. 启动 Resign，在“调度”页面选择实际使用的 Xcode。
2. 在“项目”页面添加 `.xcodeproj`、`.xcworkspace`，或者扫描一个文件夹。
3. 编辑项目，确认 Scheme、Debug/Release 配置、开发者 Team（可选）和目标设备。
4. 打开“设备”页面刷新，确认目标设备显示为可用。
5. 点击“执行全部”或项目卡片上的执行按钮。
6. 如需自动执行，在“调度”页面设置间隔和每日检查时间，然后点击“安装 / 更新”。
7. 在“日志”页面查看手动执行以及后台执行结果。

定时任务每天在指定时间检查一次。只有从上一次全部成功的日期起，已经达到设定的本地日历天数时，才会真正构建。Mac 睡眠错过日历时间后，`launchd` 会在唤醒时处理该次计划；用户退出登录或设备不可用时无法完成安装。

退出 Resign 不会卸载定时任务，后台检查由当前用户的 `launchd` 独立执行。退出 App 本身不会立刻触发构建；任务会在设定的每日时间检查是否已达到间隔。请从 `/Applications/Resign.app` 启动正式版本，避免运行 Xcode DerivedData 中残留的旧调试副本覆盖任务配置。

## 从源码构建

安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后运行：

```bash
xcodegen generate
./scripts/build-macos-app.sh
```

指定 Xcode：

```bash
XCODE_PATH=/Applications/Xcode.app ./scripts/build-macos-app.sh
```

构建并安装到 `/Applications/Resign.app`：

```bash
./scripts/install-macos-app.sh
```

运行测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Resign.xcodeproj -scheme Resign test
```

## 安装发布版

1. 在 GitHub Releases 下载 `Resign-<版本>.dmg` 和对应的 `.sha256` 文件。
2. 在下载目录校验文件：

   ```bash
   shasum -a 256 -c Resign-<版本>.dmg.sha256
   ```

3. 打开 DMG，将 `Resign.app` 拖入 `Applications`。
4. 当前公开构建未使用 Apple Developer ID 公证。首次启动时，请在 Finder 中按住 Control 点击 App，选择“打开”，再确认“打开”。后续可以正常启动。

不要关闭 Gatekeeper，也不要使用来源不明的证书或配置文件。如果你要求免除首次手动确认，应从源码自行构建，或等待经过 Developer ID 签名和 Apple 公证的版本。

## 制作 DMG

运行：

```bash
./scripts/package-dmg.sh
```

脚本默认构建同时支持 Apple 芯片和 Intel 的通用 App，创建带 `Applications` 快捷方式的 DMG、重新挂载验证 App，并生成 SHA-256 校验文件。产物保存在 `dist/`，该目录不会提交到 Git。只构建指定架构时可设置 `BUILD_ARCHS`。

拥有 Developer ID 和公证凭据时，可以通过环境变量使用它们；凭据只由 macOS 钥匙串和 Apple 工具读取，不应写入仓库：

```bash
SIGNING_IDENTITY='Developer ID Application: ...' \
NOTARY_PROFILE='your-keychain-profile' \
./scripts/package-dmg.sh
```

## 本地数据与隐私

Resign 不上传项目、设备或签名信息。Xcode 负责访问钥匙串中的开发者凭据。App 的配置和日志保存在：

```text
~/Library/Application Support/Resign/
```

LaunchAgent 配置保存在：

```text
~/Library/LaunchAgents/com.resign.auto.plist
```

日志可能包含本地项目路径、编译器输出和设备标识，因此不应直接上传到公开 Issue。仓库的忽略规则会排除配置、日志、Provisioning Profile 和常见签名文件。

## 常见错误与诊断

免费开发者账号（Personal Team）有一些限制，Resign 会在日志页直接给出中文提示，常见情况如下：

| 报错特征 | 原因 | 处理办法 |
| --- | --- | --- |
| `This provisioning profile cannot be installed on this device` / `0xe8008012` | 当前 Team 的测试设备里没有这台 iPhone/iPad | 用 Xcode 连接该设备并选它运行一次（自动注册设备），或到 Xcode → Settings → Accounts 确认设备已加入该 Apple ID |
| `MIFreeProfileValidatedAppTracker` / `maximum number of apps for free development profiles` | 免费账号每台设备最多装 3 个 App（App 扩展也占名额） | 卸载该设备上一个免费签名 App，或改用付费开发者账号 |
| `Failed Registering Bundle Identifier ... not available` | 该 Bundle ID 已被另一个开发者账号注册 | 把项目 Team 改回注册过该 Bundle ID 的账号，或修改 Bundle ID |
| `No Account for Team "XXXX"` | 所选 Team 的 Apple ID 没有登录 Xcode | 到 Xcode → Settings → Accounts 登录该账号 |
| `No profiles for ... were found` | 该 Team 下没有匹配的 Provisioning Profile | 在 Xcode 中打开项目让其自动生成 |

免费账号（不付费）的硬性限制：每台设备最多 3 个免费签名 App、每个账号最多注册 3 台测试设备、Profile 7 天过期。**多注册几个 Apple ID 并不能叠加每台设备的 3 个名额**——该限制按设备计算。需要不限数量的安装时，应使用付费的 Apple Developer Program 账号。

## 安全设计

- 交互式命令使用 `Foundation.Process` 参数数组，不通过 Shell 拼接；
- 定时脚本中的所有用户字段都采用单引号安全转义；
- DerivedData 删除操作限制在 `/tmp/ResignBuild/<项目 UUID>`；
- 安装前读取 `TARGET_BUILD_DIR` 和 `WRAPPER_NAME`，无法唯一确认主 App 时停止；
- LaunchAgent 安装会检查 `launchctl` 的真实结果，不以 plist 是否存在代替运行状态；
- 编译/签名类确定性错误不会长时间盲目重试。

## 开源许可

[MIT License](LICENSE)
