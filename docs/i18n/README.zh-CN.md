<p align="center">
  <a href="../../README.md">English</a> ·
  <b>简体中文</b> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt-BR.md">Português (Brasil)</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.hi.md">हिन्दी</a>
</p>

# Lumi by Loomtable

**你 Mac 里的那束光。**

开口一问，Lumi 就能在暗处帮你找到它，把活干完，再把答案摆到你眼前。

在任何应用里轻按一个键（默认是右 Option），开口提问。你也可以双击这个键，然后打字。Lumi 只在你按键的这一刻看一眼眼前的内容：最前面的窗口、你选中的文字、localhost 端口背后的仓库、终端所在的文件夹。看完后，它把问题交给你本机的 Claude 代理（命令行工具 `claude`，下文简称"你的代理"），由它用你自己的配置把事情办完。你会听到一句简短的语音回答。需要图示时，旁边还会出现一张卡片。Lumi 提出的改动都会等你确认。

你的代理负责思考，用的是你自己的配置：你的登录、你的 MCP 服务器、你的 CLAUDE.md。

**看着你的屏幕，听你说话。帮你找文件，替你处理文件。接入你的工具。免费、本地、开源。**

答案为你而做：一句话，需要时配一张图，再用一个圆圈标出确切的位置。不堆大段文字，Lumi 直接指给你看。问一次就会用。

为你的工作而生。创始人、设计师、分析师、写作者、学生、开发者，以及介于他们之间的每一个人。

- **官网：** [lumi.loomtable.com](https://lumi.loomtable.com)
- **下载：** [最新版本](https://github.com/loomtable/lumi/releases/latest)（DMG，见[安装](#安装)）
- **价格与许可证：** 免费，GPL-3.0
- **出品方：** [Loomtable](https://loomtable.com)，一家 AI 原生产品工作室。由 Claude 驱动。

## 系统要求

- Apple Silicon（M1 或更新）上的 macOS 26。不支持 Intel Mac 和更早的 macOS 版本。
- 已安装并登录的 `claude` 命令行工具，版本 2.1.259 或更新。你的 Claude 账号需要在 Anthropic 提供服务的国家或地区使用。
- 建议 16 GB 内存。在 8 GB 内存的机器上同时开很多应用时，回答可能会慢一些。

## 怎么用

1. 按一下 Lumi 键（默认是右 ⌥），说出你的问题。再按一下发送，或者按住这个键说话。双击则改为打字。
2. Lumi 读取你眼前的内容（见下文），然后把问题交给你的代理。
3. 你会听到一句话的回答。需要图示时，卡片会出现在你正在看的内容旁边。按 Esc、点击别处或切换应用即可关闭卡片。

问题默认先进入 Quick，用的是速度快的模型。如果问题需要用到文件、命令或浏览器，Quick 会把它转给 Deep，用更强的模型处理，并告诉你已经转过去了。在问题开头说 "go deep" 可以直接进入 Deep；以 "research" 开头则会启动一个在后台运行的长任务。在 Settings › Models 里可以为每条通道设置模型，并选择路由方式（Auto、Always Quick 或 Always Deep）。

## 读取与发送

Lumi 只在你唤起它的时候才看。它会读取：

- 最前面的应用和窗口；
- 你选中的文字、指针下方的元素，以及当前焦点输入框是否可编辑；
- 在 Lumi 能识别的情况下，最前面的应用正在显示什么：终端的文件夹和命令、本地开发服务器的端口和文件夹、编辑器的项目和文件、聊天应用的频道和对话串、访达里的文件夹及选中项；
- 你最近用过哪些应用，以及显示器的排布；
- 最前面窗口或整个显示器的截图。

它从不查看密码管理器，也不查看你在 Settings › Privacy 里屏蔽的应用。截图里不会出现这些应用的窗口。它从不读取密码输入框里的文字，不过输入框里的圆点可能会出现在截图中。命令行和网址里的敏感信息（如令牌和密钥）会在发送前被移除。

你的问题、这些上下文和截图会交给**你自己的代理**，由它发送给 Anthropic 来生成回答，使用的是你自己的 Claude 账号。Lumi 本身只在以下情况连接网络：

- 开启语音时，从 Hugging Face 下载一个小型静音检测模型（约 1 MB，只下载一次）；
- 只有在你于引导流程或 Settings › Voice 中主动选择时，才会从 Hugging Face 下载 Parakeet 语音转文字模型（约 466 MB）或 Kokoro 语音（约 437 MB），各下载一次；
- 如果你开启 ElevenLabs 语音，回复文字会发送到 ElevenLabs 进行朗读。

你在 Settings › Connections 里添加的 MCP 服务器运行在你的代理内部，会和它们各自的服务通信，跟其他 MCP 服务器一样。

默认情况下，Lumi 用 Mac 自带的语音识别和语音来听和说，不需要下载大文件。第一次使用时，macOS 可能会补装英文语音文件。语音转文字以及除 ElevenLabs 以外的所有语音都在你的 Mac 上运行，你的录音不会离开这台 Mac。截图最多在你的 Mac 上保留 24 小时，可以在 Settings › Privacy 里缩短为 6 小时或 1 小时。追踪日志默认关闭。开启后，它只记录耗时、事件类型和结果，从不记录你说了什么或看到了什么，保留 7 天。

## 安装

Lumi 以 DMG 形式发布在 GitHub Releases 上，目前还没有上架 Mac App Store 或 Homebrew。

1. 从 [Releases 页面](https://github.com/loomtable/lumi/releases/latest)下载 `Lumi-<version>.dmg` 和 `Lumi-<version>.dmg.sha256`。如需校验，在保存这两个文件的文件夹里运行 `shasum -a 256 -c Lumi-<version>.dmg.sha256`。
2. 打开磁盘映像，把 Lumi 拖到"应用程序"文件夹。
3. Lumi 目前还没有使用 Apple Developer ID 签名，所以 macOS 会拦下首次启动。先打开 Lumi 一次，关闭警告。然后打开"系统设置 › 隐私与安全性"，向下滚动，点击 Lumi 旁边的**仍要打开**，再用密码或触控 ID 确认。之后 Lumi 就能正常打开。 <!-- OWNER: 请在简体中文版 macOS 26 上核对"系统设置""隐私与安全性""仍要打开"以及下文各权限名称的实际显示文字 -->

   如果你习惯用终端，下面这条命令效果相同，且只作用于这个应用：
   ```sh
   xattr -dr com.apple.quarantine /Applications/Lumi.app
   ```
4. 按照引导流程完成设置：Lumi 键、权限和语音。

更新时，从 [Releases 页面](https://github.com/loomtable/lumi/releases/latest)下载新版本，替换"应用程序"文件夹里的 Lumi 即可。你的设置、对话和权限都会保留。

## 权限

Lumi 会在引导流程中申请以下权限，每一项都会打开"系统设置"里对应的位置：

- **输入监控**（必需）：用于识别 Lumi 键。Lumi 从不记录你输入的内容。
- **辅助功能**（必需）：用于读取你的选中内容、插入文字，以及用 Esc 关闭卡片。
- **屏幕录制**（必需）：用于随问题一起发送的截图。
- **麦克风**（可选）：用于语音提问。没有这项权限时，你随时可以打字提问。

输入监控和屏幕录制权限需要 Lumi 重新打开后才会生效，用每项旁边的 Quit & Reopen 按钮即可。

## 从源码构建

```sh
Scripts/make-dev-cert.sh   # once: a stable signing identity, so permission grants survive rebuilds
Scripts/build-app.sh       # build, sign and install /Applications/Lumi.app
open -a Lumi
```

`make-dev-cert.sh` 会请你输入一次登录密码，用来信任这张代码签名证书。第一次构建时，系统可能会询问 codesign 能否使用这把开发签名密钥，选择"始终允许"。 <!-- OWNER: 填写开发签名密钥在弹窗中显示的名称，或保持不写 -->

`INSTALL=0 Scripts/build-app.sh` 会构建 `dist/Lumi.app`，但不安装。运行 `Scripts/test.sh` 执行测试。

应用图标需要 Xcode（用到 `actool`）。没有 Xcode 时，构建会使用通用图标。

请始终从"应用程序"、聚焦或访达打开 Lumi，不要从终端启动。从终端启动的副本会借用终端的权限。

## 卸载

1. 如果你也想删除你的代理里关于 Lumi 对话的记录，请先删除它们：在 Conversations 里对每条对话使用 Forget。这些记录保存在 `~/.claude/projects/` 下，和你自己的会话混在一起。
2. 从菜单栏菜单退出 Lumi，把 `/Applications/Lumi.app` 拖到废纸篓。
3. 删除它的数据：
   ```sh
   rm -rf ~/Library/Application\ Support/com.loomtable.lumi   # conversations, reports, voice models, plugin copy
   rm -rf ~/Library/Application\ Support/Loomtable/Lumi       # saved connection tokens
   rm -rf ~/Library/Caches/com.loomtable.lumi                 # screenshots
   rm -rf ~/Library/Logs/com.loomtable.lumi                   # trace log
   rm -rf ~/Library/HTTPStorages/com.loomtable.lumi           # network cache, if present
   rm -rf ~/.cache/fluidaudio/Models/kokoro                   # the voice's pronunciation data
   defaults delete com.loomtable.lumi                         # preferences
   ```
4. 如果你添加过 ElevenLabs 密钥，打开"钥匙串访问"，搜索 `com.loomtable.lumi.elevenlabs` 并删除。
5. 如果你在 Settings › Connections 里添加过 MCP 服务器，运行 `claude mcp list` 查看，再用 `claude mcp remove --scope user <name>` 逐个移除。
6. 可选：在"系统设置 › 隐私与安全性"里，在每个列表中选中 Lumi，然后点击 −。

## Lumi 能为你多做什么

| 如果你在用… | Lumi 带来的 |
| --- | --- |
| 在终端里用 `claude` | 还是同一个代理，但可以在任何应用里调用：一个键、你的声音，再加上最前面的窗口作为上下文。你不用再贴截图，也不用解释自己在哪。 |
| 用聊天应用问 AI 问题 | 回答来自你自己的配置（仓库、CLAUDE.md、MCP 服务器、skills），不需要另一个账号和另一份记忆，答案就显示在你正在看的内容旁边。 |
| 全天录屏的助手 | Lumi 只在你按键时才看。截图最多在你的 Mac 上保留 24 小时。 |

## 常见问题

**Lumi 是什么？**
一款免费、开源的 macOS 菜单栏应用。你在任何应用里按一个键，开口问或打字问；你的代理结合屏幕上的内容给出回答。Lumi 会说一句简短的答案，需要图示时再配一张卡片。

**Lumi 免费吗？**
免费，并以 GPL-3.0 开源。你的问题经由你的代理处理，所以会计入你自己的 Claude 套餐或 API 用量。

**需要另外安装什么吗？**
需要已安装并登录的 `claude` 命令行工具，版本 2.1.259 或更新。Lumi 在你的 Mac 上运行它，自己没有登录系统，也没有服务器。

**Lumi 是 Anthropic 做的吗？**
不是。Lumi 由 Loomtable 出品，通过你的代理由 Claude 驱动，不是 Anthropic 制作的，也与 Anthropic 没有关联。

**Lumi 会发送什么，发到哪里？**
你的问题、Lumi 从最前面的应用读取的上下文，以及一张截图，会交给你的代理，再由它发送给 Anthropic 生成回答。Lumi 没有服务器，也没有数据分析。详见[读取与发送](#读取与发送)。

**Lumi 会一直盯着我的屏幕吗？**
不会。它只在你按下 Lumi 键时才看，并且会跳过密码管理器和你在 Settings › Privacy 里屏蔽的应用。

**可以不说话吗？**
可以。双击 Lumi 键就能打字。麦克风权限是可选的。

**Lumi 能改文件、跑命令吗？**
Lumi 通过你的代理工作，可以在你的 Mac 上读取、运行和编辑，也能使用你已接入的工具。Lumi 提出的改动都会等你确认。插入的文字不会替你发送，Lumi 也从不替你发送邮件或消息。

**支持 Intel Mac、旧版 macOS、Windows 或 Linux 吗？**
不支持。Lumi 需要 Apple Silicon 上的 macOS 26。

**能离线使用吗？**
不能。语音转文字和默认语音在你的 Mac 上运行，但回答来自 Claude，经由你的代理生成，需要联网。

**在中国大陆能用吗？**
Lumi 只通过你的代理使用 Claude，而你的代理需要在 Anthropic 提供服务的国家或地区登录使用。Lumi 不提供其他模型，也不提供绕过方式。

**为什么 macOS 会拦下首次启动？**
Lumi 目前还没有使用 Apple Developer ID 签名。先打开一次，然后在"系统设置 › 隐私与安全性"里点击"仍要打开"。详见[安装](#安装)。

## 仓库结构
 <!-- OWNER: 部分目录名沿用了旧的内部前缀，请确认是否在公开的翻译版中保留这张表 -->

| 路径 | 内容 |
| --- | --- |
| `Sources/BuddyCore` | 共享值类型：上下文包、回答块、模式和模型 |
| `Sources/BuddyKeys` | Lumi 键手势、限定范围的 Esc 处理、组合键 |
| `Sources/BuddyContext` | 从最前面的应用构建上下文包 |
| `Sources/BuddyAct` | 向你的应用插入文字 |
| `Sources/BuddyVoice` | 麦克风、语音转文字、文字转语音、音量表、提示音 |
| `Sources/BuddyOverlay` | 胶囊条、标签、卡片、浮层、定位、动效 |
| `Sources/BuddyBridge` | 运行你的代理并解析它的输出流 |
| `Sources/BuddyConversations` | 对话索引和代理的会话文件 |
| `Sources/BuddyTrace` | 可选的追踪日志 |
| `Sources/BuddyApp` | 负责调度每个问题的协调器、应用运行时、旧版本数据迁移 |
| `Sources/BuddyCompanion` | 设置、引导流程、Conversations |
| `Sources/Lumi` | 菜单栏应用外壳 |
| `buddy-plugin/` | 负责思考的代理插件，随应用一起发布 |
| `App/` | Info.plist、权限声明（entitlements）和应用图标（Icon Composer） |
| `Scripts/` | 构建、测试和签名脚本 |
| `Scenarios/`、`Tools/` | 回答场景以及检查这些场景的工具 |

## 许可证

GPL-3.0。© 2026 Loomtable。由 Claude 驱动。"Claude" 及其相关名称是 Anthropic 的商标；Lumi 不是 Anthropic 制作的，也与 Anthropic 没有关联。

联系我们：hello@loomtable.com

**免费、开源、本地运行。配合你的 Claude Code，在你的 Mac 上工作。**
