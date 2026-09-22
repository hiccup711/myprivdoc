# PrivDoc MVP

本地加密的可操作隐私文档。这个 MVP 先服务一个场景：把原来的敏感 txt 变成可以分类查看、字段双击复制、密钥默认隐藏、保存带历史版本的 macOS 桌面 App。

## 运行

```bash
swift run PrivDoc
```

也可以先构建：

```bash
swift build
.build/debug/PrivDoc
```

打包成可双击的 macOS App：

```bash
./build_app.sh
open PrivDoc.app
```

## 安装包与自动发布

在 [GitHub Releases](https://github.com/hiccup711/myprivdoc/releases) 下载适合芯片架构的安装包：Apple Silicon 使用 `arm64.dmg`，Intel 使用 `x86_64.dmg`。支持 macOS 14 及以上版本，打开 DMG 后将 PrivDoc 拖入 Applications。

当前安装包使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名和公证；首次打开可能需要在「系统设置 → 隐私与安全性」中允许打开。

GitHub Actions 的 `CI and Release` 工作流使用 Xcode 26.1.1，在 Apple Silicon 和 Intel runner 上运行测试、构建并验证 DMG、ZIP 和 SHA-256 校验文件。只有两种架构全部成功后才会发布 Release。

- 推送到 `main` 或向 `main` 提交 PR：自动测试和打包，安装包保留在 Actions Artifacts 14 天。
- 推送 `v主版本.次版本.补丁版本` 标签（如 `v0.1.1`）：自动发布对应版本的 GitHub Release。
- 也可在 Actions → CI and Release → Run workflow 选择 `main`，填写版本号（如 `0.1.1`，不带 `v`），成功后自动创建标签并发布 Release。已发布版本不会被覆盖。

在本机生成当前芯片架构的安装包：

```bash
VERSION=0.1.0 ./build_release.sh
```

产物保存在 `dist/`，版本号同时写入 App 的 `Info.plist`。发布其他版本时修改 `VERSION` 即可。

## 现在能体验什么

- 新建一个本地密档
- 查看态自动拆分 `字段名：字段值`
- 密钥字段默认显示为“已隐藏，双击复制”
- 普通字段和密钥字段都可以双击复制
- 剪贴板清理可配置：5 秒、15 秒、30 秒、1 分钟、5 分钟、手动清除
- 只清理 PrivDoc 自己写入的那次剪贴板，不会误删你之后复制的新内容
- 搜索标题、字段名、非密钥字段值
- Smart View 会把混乱原文解析成条目和可操作项，不要求先整理格式
- 支持识别裸邮箱、裸密钥、SSH 命令、1Panel 日志和面板 URL
- 面板 URL 会隐藏随机路径 token，但复制时复制完整 URL
- URL 内嵌凭据和敏感查询参数不会显示，也不会进入搜索
- 编辑态保留 Markdown-ish 原文
- 新密档首次加密落盘后才允许进入编辑、历史、规则和设置
- 保存时生成历史版本
- 首次保存只有在加密文件实际写入成功后才会提示成功
- 离开未保存编辑或锁定未落盘密档前会要求明确确认
- 正常退出 App 也会经过同一套未保存确认
- 文档密码需要输入两次，避免输错后无法解锁
- 密码解锁会显示“解锁中...”，进行中禁止重复提交和关闭弹窗；密码学计算不阻塞主界面
- 历史 Diff 覆盖标题、正文、字段、裸密钥、邮箱、SSH 和 URL；重复同名内容不会互相覆盖
- 历史里的密钥前后值始终只显示“已隐藏”，敏感 URL 和原文预览使用 Smart View 安全投影
- 规则页管理自定义密钥词、强制普通字段和条目标题词；支持手动添加、查看、删除和持久化
- 设置页管理剪贴板清理策略
- 设置页管理自动锁定时间，Mac 睡眠或锁屏时会立即锁定
- 保存为 `.privdoc` 加密文件，使用文档密码，不接入 macOS 钥匙串
- 打开新 `.privdoc` 后用文档密码解锁；旧系统授权文件继续兼容

## 当前安全实现

MVP 使用 `PBKDF2-HMAC-SHA256 + AES-GCM` 加密 `.privdoc` 文件。v1 密码文件只接受 310,000 次迭代和 16-byte salt；nonce 必须是 12 bytes，密文至少包含 16-byte GCM tag。未知 `authMode` 会被拒绝，只有缺失 `authMode` 的旧文件会兼容为密码模式。

旧系统授权文件也会严格校验固定 KDF、空 salt、0 次迭代和 UUID `keyID`。畸形 JSON 统一按无效格式处理。加解密会在后台任务执行，但自动持久化仍保留同步路径。

下一步建议把 KDF 升级为 `Argon2id`，并加入更完整的内存清理和安全偏好设置。

## 解锁模式

当前 MVP 新保存的密档只使用文档密码：

- 文档密码：用户设置一个密码，文件可迁移到其他电脑再用密码解锁；不接入 macOS 钥匙串，行为最透明。

曾经试过系统授权模式：PrivDoc 生成随机 256-bit 密钥，把密钥放进 macOS Keychain，再通过 Touch ID 或 Mac 密码读取。但开发版可能暴露钥匙串访问确认，信任感不好，所以已经从新建保存流程移除。

已经保存成系统授权的旧 `.privdoc` 暂时仍可打开，方便把数据迁移回文档密码模式。

## 文档格式

编辑态里可以直接写：

```markdown
## 服务器 / prod-01

服务器IP：192.0.2.10
SSH用户：root
SSH端口：22
服务器登录密码：replace-me-password
OnePanel地址：https://example.com:8443
OnePanel账号：admin
OnePanel密码：replace-me-panel-password
备注：主站生产服务器
```

字段名包含 `密码`、`密钥`、`token`、`secret`、`key`、`cookie`、`恢复码` 等词时，会被识别为密钥字段。

也可以用显式标记覆盖自动规则：

```markdown
服务器密码：{{abc123}}
{{一整段不想展示的内容}}
备注：公开部分 {{私密部分}} 公开部分
临时 Token：xxxx @secret
Public Key：ssh-rsa AAAA... @text
```

用 `{{...}}` 包起来的内容会在查看态隐藏，双击隐藏片段会复制原始内容。用户不需要说明它为什么私密。

优先级是：双大括号隐藏 > 行尾显式标记 > 用户规则 > 内置规则 > 自动类型判断。

## 识别规则

规则是 App 级全局配置，不写进单个 `.privdoc`。你添加一次之后，之后打开的所有密档都会按同一套习惯识别。

- 自定义密钥词：字段名包含这些词时，值会被隐藏。
- 强制普通字段：字段名包含这些词时，不会被识别为密钥。
- 条目标题词：条目已有内容后，遇到包含这些词的独立行时，从这里开始新条目。

查看态里也可以右键某个字段，直接把这个字段名加入密钥规则或普通字段规则。

## 验证

```bash
swift test
```

当前共 75 个测试通过：11 个加密格式、14 个历史 Diff、1 个基础文档解析、30 个 Smart Parser、19 个状态与规则测试。
