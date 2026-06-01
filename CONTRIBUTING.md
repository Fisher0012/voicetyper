# 给 VoiceTyper 贡献代码

欢迎 PR、Issue、idea。这个项目目前是 [Donnie](https://github.com/Fisher0012) 自用 + 业余维护,响应可能不快,但欢迎贡献。

## 开发环境

- macOS 14.0+ (推荐 15+)
- Xcode 16+
- Apple Silicon
- [xcodegen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)

## 本地开发

```bash
git clone https://github.com/Fisher0012/voicetyper.git
cd voicetyper
xcodegen generate
open GhostPepper.xcodeproj
```

在 Xcode 里:
1. Signing & Capabilities → Team 选你自己的 Apple ID
2. Cmd+R 跑起来

## 改完代码,部署测试

```bash
# 完整脚本(替换 sign identity 为你自己的)
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper \
  -configuration Release \
  -derivedDataPath ./build-release \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  build

# 部署
pkill -f "VoiceTyper.app/Contents/MacOS/GhostPepper" 2>/dev/null
mv /Applications/VoiceTyper.app ~/.Trash/VoiceTyper-old-$(date +%H%M%S).app 2>/dev/null
cp -R build-release/Build/Products/Release/GhostPepper.app /Applications/VoiceTyper.app
xattr -cr /Applications/VoiceTyper.app
codesign --force --deep --preserve-metadata=entitlements \
  --sign "Apple Development" /Applications/VoiceTyper.app
open /Applications/VoiceTyper.app
```

## 项目设计原则

如果你想改动核心层(ASR / LLM cleanup / hotkey),**先读完这些原则**:

### 1. 100% 本地,不可破坏
- 不引入云端 API 调用(包括 Anthropic / OpenAI 等)
- 不引入需要联网的依赖
- 用户应该能在飞行模式下完整使用

### 2. Systemic over reactive
**不要** "用户报错→打补丁→破坏其他场景→用户再报错" 的循环。改动前问自己:

> "这个改动是 systemic 通用规则,还是只针对这一个 case 的硬编码?"

如果是"加错例字典"、"用 regex 匹配特定关键词"等做法,**几乎一定是 reactive 补丁**,要重新考虑。

举例:
- 🟥 **Reactive 补丁**:用户说 "Typeless" 被识别成 "Tables" → 在 prompt 里加一行 `如果看到 Tables 在讨论语音工具,改成 Typeless`
- 🟩 **Systemic 方案**:加通用 SAME-CONCEPT CONSISTENCY 规则(同段内同概念多变体统一为最清晰版本),适用任何专名

### 3. 评测先行
改 `TextCleaner.swift` 的 prompt、`VADMonitor.swift` 的阈值、`SpeechModelCatalog.swift` 的模型选型前:
1. 先看 `GhostPepper/QualityEvalCases.swift` 里有没有相关 case
2. 如果有,改动后回归这些 case 看是否退化
3. 用户报告的新错误 → 加成新 case → 然后才改改动

### 4. Prompt 设计:产品化任务,不是规则列表
TextCleaner.defaultPrompt 是 VoiceTyper 的灵魂。设计原则:
- 角色 + 核心任务优先级,不是 "Rule 1 / Rule 2 / ..."
- 自我纠正用语义层例子,不是关键词列表
- 中文示例和英文示例并重

## 可能想做但还没做的事

如果你想动手:

### 短期 / 容易
- [ ] **设置 UI 改进**:Onboarding 引导、热键自定义 UI、模型切换 UI
- [ ] **图标设计**:目前用 SF Symbol(`mic.fill` / `waveform.circle.fill`)占位,需要真正的 app 图标
- [ ] **i18n**:界面文案现在中英混杂,可以做完整 i18n
- [ ] **CI**:加 GitHub Actions 跑 xcodebuild 验证

### 中期 / 工程量
- [ ] **风格学习**(参考 Typeless):从用户历史 paste 内容里学写作风格,作为 prompt 注入
- [ ] **按目标 app 切语气**:Gmail 写邮件、Slack 写聊天、Cursor 写代码——不同上下文不同的清理 prompt
- [ ] **流式 ASR**:边录边显示部分转写结果(目前是录完才显示)
- [ ] **词典 UI**:在 Settings 里增删 `custom-terms.txt`,不必手动编辑文件

### 长期 / 探索性
- [ ] **个性化模型微调**:基于用户语音样本做 Whisper LoRA 微调
- [ ] **翻译模式**(参考 Typeless):独立快捷键触发口述源语言→目标语言翻译
- [ ] **多平台**:目前只 macOS,iOS 是否值得做?

## Bug 报告

如果遇到识别错误或质量问题,请提 issue 时附上:

1. 你说的原话(尽量准确写出来)
2. VoiceTyper 输出的转写
3. 期望的输出
4. **Debug Log**:菜单栏 → Debug Log → 复制最后 50 行

最好的是把这条新 case 加到 `GhostPepper/QualityEvalCases.swift`,作为 PR 一部分。

## Issue / PR 沟通

- 中文/英文都可以
- 大改动建议先开 Issue 讨论方向
- 小改动(typo / 文档 / 单点 bug fix)直接 PR
