# VoiceTyper

**100% 本地、面向 Vibe Coding 的 macOS 语音输入工具。**

按一下右 Cmd 说话,再按一下停止;它把你的口述整理成连贯、带标点、自动断句的书面文字,粘贴到光标位置。所有处理都在你的 Mac 本地完成——音频、文字、模型,没有任何数据离开你的设备。

**对标 [Typeless](https://typeless.app/)**(一款云端语音输入工具),但选择了一条不同的路:**所有处理本地、可审计、零账号、零订阅**。

---

## 为什么做这个

我是 [Donnie](https://github.com/Fisher0012),做产品 + 写代码。我大量时间在和 AI 工具(Claude Code、Cursor)对话,用键盘打字慢、容易打断思路。Typeless 用着很顺手,但它是**云端架构**(音频实时上传 AWS 处理,虽然官方说"零保留 / 不训练",但流量本质上离开了你的设备),且需要订阅。

我想要的是:
- **真本地**——音频从来不离开 Mac,任何时候断网都能用
- **没有账号、订阅、配额限制**——装上就用,永久
- **代码可审计**——开源,任何人可以验证它真的不联网
- **质量逼近 Typeless**——自我纠正、上下文一致性、专有名词识别

VoiceTyper 是基于 [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper)(MIT)fork 改造而来,经过裁剪、重新架构、模型升级,对标 Typeless 的体验做了大量产品化打磨。

---

## 核心特性

### 🔒 默认 100% 本地,可选云端 LLM 加速

**默认 100% 本地**(无账号无订阅): ASR(WhisperKit / large-v3-turbo)和 LLM 清理(Qwen 3.5 4B)都跑在你的 Mac。

**可选云端 LLM 清理**(为速度/质量牺牲一点隐私): Settings → Cleanup → backend 选 "Claude API" 或 "OpenAI-Compatible"。后者支持任意 OpenAI 兼容 endpoint(推荐 [MiniMax](https://platform.minimax.io/),约 1/20 Claude 价格,中文能力强)。**音频依然本地处理**,只有清理阶段的文字过云端。云端调用失败时自动 fallback 本地。


- ASR 模型(Whisper Large v3 Turbo)和清理 LLM(Qwen 3.5 4B)都在 Apple Silicon 本地跑
- 模型从 Hugging Face 一次性下载,之后完全离线
- 没有任何账号系统、API key、订阅、远程更新
- 你可以 grep 代码或断网验证

### 🎙️ 智能整理(不只是转写)
按 [Typeless](https://typeless.app/) 调研出的产品逻辑做了系统性整理(参见 [docs/RESEARCH.md](docs/RESEARCH.md)):

| 能力 | 实现 |
|---|---|
| **自我纠正(LLM 推断意图)** | "明天三点开会,算了改成四点" → "明天四点开会"。靠 LLM 语义理解,不是关键词匹配 |
| **同概念一致性** | 一段里同个专名 ASR 听成不同变体(Tables / Typeless / Taplease)→ 统一为最清晰那个 |
| **碎片→结构化** | 长串无停顿的口述 → 自动断句、加标点、分段 |
| **中英混说** | 自动识别中英文混合,中英之间加空格,保留专有名词大小写 |
| **繁→简硬转换** | Apple ICU 100% 确定性繁转简(whisper 多语言模型常输出繁体) |
| **领域词典** | 用户在 `custom-terms.txt` 预设常用术语,作为 LLM 修错的 anchor |
| **VAD 自动停止** | 连续 2 秒静音自动结束录音,不必按第二下 |
| **填充词清理** | 中英填充词(嗯/啊/那个/um/uh/like)智能删除,保留实义用法 |

### ⚡ Vibe Coding 友好
- 单热键 toggle:**右 Cmd** 按一次开始、再按一次停止(不需要按住)
- **右 Option** 备用 push-to-talk(按住说话、松开停止)
- 录音时屏幕底部脉冲红点提示
- 转写完直接 Cmd+V 注入光标位置——任何 app:Cursor / Terminal / 备忘录 / 浏览器都行

---

## 系统要求

- **macOS 14.0+**(推荐 macOS 15+ 以解锁 FluidAudio 路径)
- **Apple Silicon**(M1 及以上)
- **磁盘空间**:模型首次下载约 **5GB**(Whisper Large v3 Turbo ~1.5GB + Qwen 3.5 4B ~2.8GB)
- **权限**:麦克风、辅助功能(Accessibility)

---

## 安装

### 🤖 方式 0:用 Claude Code 一键安装(推荐,最简单)

如果你用 [Claude Code](https://claude.ai/code),装个 skill 后一句话搞定全程:

```bash
# 1. 把 skill 装到你的 Claude Code 用户 skills 目录
mkdir -p ~/.claude/skills/voicetyper-install
curl -fsSL https://raw.githubusercontent.com/Fisher0012/voicetyper/main/skills/voicetyper-install/SKILL.md \
  -o ~/.claude/skills/voicetyper-install/SKILL.md
```

然后在你的 Claude Code 里说:**"帮我装 voicetyper"**

Claude 会自动:
1. 检查前置(macOS 14+ / Apple Silicon / Xcode / Homebrew / xcodegen / 签名证书)
2. `git clone` 仓库到 `~/Developer/voicetyper`
3. 跑 [`scripts/install.sh`](scripts/install.sh):xcodegen → xcodebuild Release → cp 到 `/Applications` → codesign 重签
4. 打开"辅助功能"设置面板,引导你授权
5. 启动 app + 告诉你怎么用

全程不需要你跑命令、不需要懂 xcodebuild。

### 方式 1:用 install.sh 脚本(手动)

```bash
git clone https://github.com/Fisher0012/voicetyper.git ~/Developer/voicetyper
cd ~/Developer/voicetyper
bash scripts/install.sh
```

脚本干的事跟 skill 一样,只是需要你手动跑命令 + 自己开授权面板。

### 方式 2:从源码完全手动构建

需要 Xcode 16+ 和 [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
# 安装 xcodegen
brew install xcodegen

# clone & build
git clone https://github.com/Fisher0012/voicetyper.git
cd voicetyper
xcodegen generate

# 用你自己的 Apple Development 证书构建
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper \
  -configuration Release \
  -derivedDataPath ./build-release \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  build

# 部署到 /Applications
cp -R build-release/Build/Products/Release/GhostPepper.app /Applications/VoiceTyper.app
xattr -cr /Applications/VoiceTyper.app

# 用你自己的开发者证书重签
codesign --force --deep --preserve-metadata=entitlements \
  --sign "Apple Development" \
  /Applications/VoiceTyper.app

open /Applications/VoiceTyper.app
```

### 第一次启动需要的授权

1. **麦克风**:首次按右 Cmd 录音时会弹出请求
2. **辅助功能**(Accessibility):用于监听全局热键 + 模拟 Cmd+V 注入文字
   - 系统设置 → 隐私与安全 → 辅助功能 → 加 VoiceTyper

授权完无需重启,首次会下载 ~5GB 模型(菜单栏显示进度),下完即可使用。

---

## 使用

### 默认热键
- **按一下右 Cmd** → 开始录音(屏幕底部出现红色脉冲)
- **再按一下右 Cmd** → 停止 + 转写 + 粘贴
- **或** 说完不按,静音 2 秒自动停(VAD)
- **按住右 Option** → 边按边说,松开停(push-to-talk 模式)

### 自定义术语字典

如果你常用某些专有名词、品牌、行业术语,编辑这个文件:

```
~/Library/Application Support/GhostPepper/custom-terms.txt
```

每行一个术语,`#` 开头是注释。保存后下次录音自动生效。

例:
```
# 我常用的工具
Cursor
Claude Code
VoiceTyper
ChatGPT
HTTPS
React
```

LLM 在清理时会优先匹配这些词——你说 "Tables / Taplease",它知道你大概率是说 "Typeless"。

### 自我纠正(Typeless 风格)

直接像平时说话一样说错就改,LLM 会保留你最终的意图:

```
你说: "明天三点开会,算了改成四点"
输出: "明天四点开会。"

你说: "用 React,等等不对,用 Vue"
输出: "用 Vue。"

你说: "balabala 一通,我重新讲一遍,这次重点是 XYZ"
输出: "XYZ"
```

不需要关键词("scratch that"等)——LLM 推断意图,你怎么自然说怎么说。

---

## 架构与技术决策

### 技术栈
| 层 | 用什么 | 为什么 |
|---|---|---|
| ASR | [WhisperKit](https://github.com/argmaxinc/WhisperKit) + Whisper Large v3 Turbo | 精度顶级 + CoreML 加速 |
| LLM 清理 | [LLM.swift](https://github.com/obra/LLM.swift)(llama.cpp Swift 绑定)+ Qwen 3.5 4B Q4_K_M | 4B 是本地能跑的最大可用语义模型 |
| 热键 | `NSEvent.addGlobalMonitorForEvents` | 不需要 Input Monitoring 权限,只需 Accessibility |
| 粘贴 | `CGEvent.post` Cmd+V | 直接注入到目标 app |
| 繁→简 | Apple ICU `Hant-Hans` | 100% 确定性,不依赖 LLM |
| VAD | 自研 RMS 状态机(`VADMonitor.swift`)| 简单可靠,无外部依赖 |

### 核心 prompt 设计哲学

参见 [`GhostPepper/Cleanup/TextCleaner.swift`](GhostPepper/Cleanup/TextCleaner.swift) 的 `defaultPrompt`——这是 VoiceTyper 的灵魂。设计原则:

- **角色化**:LLM 是"专业口述整理助手",不是规则机器人
- **任务优先级**:推断意图 → 同概念一致性 → 删填充词 → 修 ASR 误识别 → 碎片整理成结构化
- **不靠关键词列表**:自我纠正示例用语义层例子("coffee, actually boba"),让 LLM 学**意图模式**

### 与 Typeless 的差异
| 维度 | Typeless | VoiceTyper |
|---|---|---|
| 处理位置 | 云端(AWS us-east-2) | **100% 本地** |
| 账号 | 必需 | **无** |
| 订阅 | 必需(Pro 解锁完整能力) | **永久免费** |
| ASR 模型 | 未公开 | Whisper Large v3 Turbo(公开) |
| LLM 模型 | 未公开(可能 GPT-4 / Claude) | Qwen 3.5 4B(公开) |
| 单段时长上限 | 6 分钟 | 无 |
| 多语言 | 100+(翻译模式) | 多语言 |
| 风格学习 / 按 app 切语气 | 有 | 暂无 |

LLM 后处理质量上 Typeless 当前更强(云端大模型)。本地 Qwen 4B 在多数 Vibe Coding 场景已经接近可用,但**这是一个明确的差距**。

---

## 项目结构

```
voicetyper/
├── GhostPepper/                # app 源码(目录名保留是因为 fork 自 ghost-pepper)
│   ├── Audio/                  # 音频录制 + 音效
│   ├── Cleanup/                # LLM 清理层(TextCleaner.swift 含核心 prompt)
│   ├── Context/                # 焦点元素定位 + OCR(OCR 默认关闭)
│   ├── Input/                  # 全局热键 + 文字粘贴
│   ├── Transcription/          # ASR 调度
│   ├── UI/                     # 菜单栏 + 设置窗口 + 录音浮层
│   ├── VADMonitor.swift        # 静音自动停止
│   ├── TermHistoryStore.swift  # 用户术语字典
│   ├── QualityEvalCases.swift  # 质量评测集
│   └── AppState.swift          # 主状态
├── GhostPepperTests/           # 单元测试
├── Config/                     # 签名配置(LocalSigning gitignored)
├── docs/                       # 文档
│   └── RESEARCH.md             # Typeless 调研报告
├── project.yml                 # xcodegen 工程定义
└── LICENSE                     # MIT(继承自上游 + Donnie 新增代码 MIT 二段授权)
```

---

## 关于来源与致谢

VoiceTyper 基于 [**matthartman/ghost-pepper**](https://github.com/matthartman/ghost-pepper)(MIT,作者 [Matt Hartman](https://github.com/matthartman))fork 改造而来。

上游 Ghost Pepper 提供了:
- macOS SwiftUI MenuBarExtra 基座
- WhisperKit / LLM.swift / FluidAudio 集成
- 转写录音粘贴的工程骨架

我做的:
- 裁剪掉会议转录、QA、PepperChat、Trello、Zo 等扩展功能,聚焦到"纯语音输入"
- 重构 cleanup prompt 为产品化任务设计(基于对 Typeless 的实际调研)
- 加入用户领域词典、VAD 自动停止、繁简硬转换、质量评测集
- 用开发者证书签名 + 部署流程改造

详细演变史见 [docs/RESEARCH.md](docs/RESEARCH.md)。

---

## License

MIT。

VoiceTyper 包含:
- 来自上游 [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper) 的代码,版权 (c) 2026 Matt Hartman
- VoiceTyper 新增/修改的代码,版权 (c) 2026 Donnie ([@Fisher0012](https://github.com/Fisher0012))

两部分均 MIT 授权。完整文本见 [LICENSE](LICENSE)。

---

## 致谢

- [Matt Hartman](https://github.com/matthartman) — Ghost Pepper 项目作者,提供了优秀的工程基座
- [WhisperKit](https://github.com/argmaxinc/WhisperKit)(argmaxinc) — Apple Silicon 优化的 Whisper 实现
- [LLM.swift](https://github.com/obra/LLM.swift) — Swift llama.cpp 绑定
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — 多语言 ASR 路径(可选)
- [Typeless](https://typeless.app/) — 产品体验灵感
- [Hugging Face](https://huggingface.co/) — 模型分发
- [Claude](https://claude.ai/) — 编程协助
