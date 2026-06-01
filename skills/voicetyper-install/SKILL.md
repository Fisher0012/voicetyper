---
name: voicetyper-install
description: 安装 VoiceTyper(100% 本地的 macOS 语音输入工具,对标 Typeless)。当用户说"装 voicetyper"、"install voicetyper"、"帮我装语音输入工具"或类似意图时调用。需要 macOS 14+ 的 Apple Silicon Mac、Xcode、Homebrew。Skill 会自动 clone 仓库、构建、签名、部署到 /Applications,然后引导用户授权 Accessibility。
---

# 安装 VoiceTyper

你的任务是帮用户在他的 Mac 上安装 [VoiceTyper](https://github.com/Fisher0012/voicetyper) — 一个 100% 本地的菜单栏语音输入工具,对标 Typeless 体验。

## 执行步骤

按以下顺序做,**每步出错都停下来告诉用户怎么修**。

### 1. 前置检查

跑这些命令(在一次 Bash 调用里),收集环境信息:

```bash
sw_vers -productVersion        # macOS 版本(必须 14+)
uname -m                        # 必须 arm64
xcode-select -p 2>/dev/null     # Xcode 路径(必须有)
which brew 2>/dev/null          # Homebrew(必须有)
which xcodegen 2>/dev/null      # xcodegen(没有的话用 brew install)
which gh 2>/dev/null && gh auth status 2>&1 | head -3   # 可选
security find-identity -v -p codesigning 2>&1 | grep "Apple Development" | head -1   # 是否有开发证书
```

不满足的检查项:
- macOS < 14:停止,告诉用户必须升级 macOS
- 不是 arm64:停止,本工具只支持 Apple Silicon
- 没 Xcode:让用户 App Store 装 Xcode 后重来
- 没 Homebrew:给用户 https://brew.sh 安装链接
- 没 xcodegen:运行 `brew install xcodegen`(可以自动做)
- 没 Apple Development 证书:告诉用户在 Xcode → Settings → Accounts 登录 Apple ID 即可自动获得

### 2. Clone 仓库

```bash
INSTALL_DIR="${HOME}/Developer/voicetyper"
mkdir -p "${HOME}/Developer"
if [ -d "$INSTALL_DIR" ]; then
  echo "$INSTALL_DIR 已存在,拉最新代码"
  cd "$INSTALL_DIR" && git pull
else
  git clone https://github.com/Fisher0012/voicetyper.git "$INSTALL_DIR"
fi
```

如果用户已有同名目录但不是这个仓库,问用户怎么处理(挪走 / 换位置)。

### 3. 跑安装脚本

```bash
cd ~/Developer/voicetyper
bash scripts/install.sh
```

这个脚本会:
1. `xcodegen generate` 生成 Xcode 工程
2. `xcodebuild` Release 构建(首次约 3-5 分钟)
3. 备份现有 `/Applications/VoiceTyper.app`(若有)到废纸篓
4. 把新构建 cp 到 `/Applications/VoiceTyper.app`
5. `xattr -cr` + `codesign --sign "Apple Development"` 用用户的开发证书重签
6. `open` 启动 app

脚本如果失败,**完整显示错误输出**给用户,常见原因:
- 证书选择错误 → 让用户检查 `security find-identity` 看 Apple Development 证书名
- Xcode CLT 没装 → `xcode-select --install`
- 模型下载需要联网 → 提示用户保持联网,首次启动会下载 ~5GB 模型

### 4. 授权引导

构建+部署完成后:
1. 打开"辅助功能"设置面板:
   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```
2. 引导用户:
   > 在弹出的"辅助功能"列表里,如果**没有** VoiceTyper:
   > - 点 **+** → Cmd+Shift+G → 粘贴 `/Applications/VoiceTyper.app` → 回车 → 选中
   > 如果**有**(但开关灰色):
   > - 直接打开开关让它变蓝
3. 等用户回复"好了"再继续

### 5. 启动 + 使用引导

授权完成后:
```bash
pkill -f "VoiceTyper.app/Contents/MacOS/GhostPepper" 2>/dev/null
sleep 1
open /Applications/VoiceTyper.app
```

告诉用户:

> ✓ VoiceTyper 已就绪。**首次启动会下载 ~5GB 模型**(Whisper Large v3 Turbo + Qwen 4B),菜单栏图标会显示进度。
>
> 下载完后:
> - 找一个文本框(备忘录 / Safari 地址栏 / 编辑器都行)
> - 点光标进文本框,**按一下右 Cmd** → 屏幕底部出现脉冲红点 = 录音中
> - 说一段话
> - **再按一下右 Cmd** 停止(或者说完直接静音 2 秒,VAD 自动停)
> - 文字会自动粘贴到光标处
>
> **个性化术语字典**:编辑 `~/Library/Application Support/GhostPepper/custom-terms.txt`,每行一个你常用的专有名词(如 React、HTTPS、产品名等),保存后下次录音自动生效。
>
> 完整使用文档: https://github.com/Fisher0012/voicetyper#使用

### 6. 错误处理

- **构建失败**:把 build log 完整显示给用户,问他要不要保留还是回滚
- **签名失败**:常见是没 Apple Development 证书,引导去 Xcode 登 Apple ID
- **app 启动失败**:`open` 命令报错时,告诉用户右键 `/Applications/VoiceTyper.app` → 打开(绕过 Gatekeeper 第一次警告)
- **授权后还是没反应**:可能是 TCC 缓存,运行 `tccutil reset Accessibility com.donnie.voicetyper.next` 然后重启 app

## 注意事项

- **不要修改用户的 Xcode 设置或全局 Apple ID 配置**
- **不要用 sudo**(整个流程不需要 root 权限)
- 用户主动询问时才汇报详细日志,默认简洁汇报
- 中文沟通(项目作者中文母语)
