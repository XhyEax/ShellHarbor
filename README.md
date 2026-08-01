# ShellHarbor

ShellHarbor 是一个原生 macOS SSH 与 SCP 图形客户端。界面采用类似 Xshell/Xftp 的工作区布局：左侧管理持久化 Remote，右侧管理运行中的 Session，并可在终端、双栏文件传输和组合工作台之间切换。

## 已实现

- SSH Remote 的新建、编辑、复制、删除与本地持久化
- `shcli ls` 列出 Remote；`shcli c <名称、序号或 UUID>` 在当前终端连接交互式 SSH shell
- 双击 Remote 创建 Session；同一个 Remote 可同时创建多个独立 Session
- Remote 可选择另一个已有 Remote 作为 JumpHost 代理，并选择 ProxyJump 或 Forward 实现
- 网络 Proxy 支持基于官方 tsnet 的内置 Tailscale 节点，可配置 AuthKey 与自定义 Login Server
- Session 标签切换与关闭，每个 Session 独立保存 PTY、路径、history 和传输队列
- 密码、私钥、SSH Agent 三种认证方式
- GUI 密码连接通过 `sshpass` 完成；`shcli` 使用匿名文件描述符传递密码，不写入参数、环境变量、日志或临时文件
- 基于 PTY 的真正交互式 SSH 终端，不使用独立命令输入框
- ANSI/VT100/xterm-256color 渲染、光标移动、全屏缓冲区、鼠标事件和窗口尺寸同步
- 支持方向键、Tab 补全、Ctrl-C，以及 `vim`、`top` 等全屏交互程序
- 夜间、石墨、Solarized Dark 与浅色主题；默认夜间模式
- 从远端 zsh、bash、fish history 文件读取、搜索并回填命令
- 本地与远程双栏文件浏览
- SCP 文件/文件夹上传和下载、传输状态与错误日志
- 远程目录创建、刷新、进入、返回上级及确认删除
- 主机密钥策略、端口、保活间隔与远程起始目录设置

## 环境要求

- macOS 14 或更新版本
- Xcode 16 或更新版本（源码构建）
- 密码认证需要 `sshpass`

本项目会自动检查以下路径：

```text
/opt/homebrew/bin/sshpass
/usr/local/bin/sshpass
/opt/local/bin/sshpass
```

Homebrew 可使用下列命令安装：

```bash
brew install hudochenkov/sshpass/sshpass
```

## 运行与打包

调试运行：

```bash
swift run ShellHarbor
```

执行测试：

```bash
swift test
```

生成可双击运行的 `.app`：

```bash
chmod +x scripts/package_app.sh
./scripts/package_app.sh
open dist/ShellHarbor.app
```

生成的应用位于 `dist/ShellHarbor.app`，使用本机临时签名。正式分发需要替换 Bundle ID，并使用 Apple Developer ID 签名和公证。

打包后可直接使用 CLI：

```bash
dist/shcli ls
dist/shcli c iphone-2222
dist/shcli c 1
```

App 设置中的“链接到 Homebrew bin”默认开启，会安全创建 `/opt/homebrew/bin/shcli`；关闭时只移除仍指向 ShellHarbor 自身的链接。

## 安全说明

- 密码以 RSA-2048 OAEP + AES-GCM 密文保存在 ShellHarbor 本地配置中，私钥文件权限为当前用户可读。
- `shcli ls` 不解密密码；连接时只解密目标及其跳板 Remote，并通过匿名管道交给 `sshpass -d`。
- 新 Remote 默认遵循 OpenSSH 的交互式主机密钥确认；选择“自动接受新主机”时使用 `StrictHostKeyChecking=accept-new`，已记录密钥发生变化时仍会拒绝连接。
- 远程删除会显示确认，并明确提示不可撤销。

## 终端实现

终端视图使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.15.0。`ssh` 或 `sshpass` 运行在本地伪终端（PTY）中，键盘输入会直接写入 PTY，远端输出则由 VT/xterm 解析器渲染。ANSI 控制序列不会作为字符显示，而会正确控制颜色、光标、清屏和备用屏幕。
