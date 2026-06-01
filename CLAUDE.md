# CLAUDE.md — Claude Code 协作指南

这个文件给 [Claude Code](https://claude.ai/code) 看,帮它在这个项目里工作得更好。

## 项目一句话总结

VoiceTyper 是一个 100% 本地的 macOS 菜单栏语音输入工具,从 [matthartman/ghost-pepper](https://github.com/matthartman/ghost-pepper)(MIT)fork 改造,对标 [Typeless](https://typeless.app/) 体验但保持本地。

## 核心架构关键点

### 录音/转写/粘贴流水线

入口:`GhostPepper/AppState.swift`

1. `startHotkeyMonitor()` — 监听全局热键(NSEvent global monitor,不是 CGEventTap)
2. 用户按右 Cmd → `startRecording()` → `AudioRecorder.startRecording()` 走 AVAudioEngine
3. 用户再按或 VAD 触发 → `stopRecordingAndTranscribe()`
4. `processRecordingResult()` → `transcribedTextForRecording()` → WhisperKit batch 转写
5. `cleanedTranscriptionResult()` → `TextCleaner.cleanWithPerformance()` → Qwen 4B
6. `textPaster.paste()` → `CGEvent.post` 模拟 Cmd+V

**绝对不要改这条链路的逻辑语义**——稳定性优先。如果一定要动,加 testcase 到 `QualityEvalCases.swift`,改前/改后跑评测。

### Cleanup prompt 是项目灵魂

`GhostPepper/Cleanup/TextCleaner.swift` 的 `defaultPrompt` 决定了 VoiceTyper 整理质量。设计原则:

- **角色化任务**,不是规则机器人
- **任务优先级**:推断意图 → 同概念一致性 → 删填充词 → 修 ASR 误识别 → 碎片整理
- **不靠关键词列表**——自我纠正用语义层例子("coffee, actually boba")

改 prompt 前先读 `docs/RESEARCH.md`(Typeless 调研报告)和 prompt 现有结构。

### 100% 本地是硬约束

- 不引入云端 API 调用
- 不引入需要联网的依赖
- LLM 用 Qwen 4B(`LLM.swift` + llama.cpp + GGUF),ASR 用 WhisperKit(CoreML)
- Anthropic / OpenAI / Google API 调用是禁区

## Donnie 的协作偏好(重要)

### 反对 reactive 补丁

Donnie 多次明确反对"用户报一个错→打一个补丁"的优化模式。**遇到识别错误/质量问题,先归因到结构层**(模型 / 架构 / prompt 设计 / 数据),不要立即在 prompt 加错例或代码加 regex 补丁。

判断标准:**"这个改动是 systemic 通用规则,还是只针对这一个 case 的硬编码?"**

### 调研驱动决策

涉及对标第三方产品(如 Typeless)或选模型/选架构时,**先调研真实实现再决策**,不要靠产品话术或猜测。`docs/RESEARCH.md` 是 Typeless 真实架构的调研结论,所有"VoiceTyper vs Typeless"的对比应基于此。

### 沟通风格

- 中文沟通,代码注释中文,变量函数英文
- 先结论再细节
- 不要客套("好的我明白了""没问题")
- 不要自我粉饰("整体顺利")
- 遇到决策点停下问,**不要猜**

### 严禁编造数字

任何"识别率提升 X%""精度 Y"等具体数字,必须有可验证来源(实测日志、调研引用)。**禁止编造**。

如果要给指标,先在 `QualityEvalCases.swift` 跑实际评测,引用数字。

## 常用命令

```bash
# 生成 Xcode 工程
xcodegen generate

# build & 部署
./scripts/build-and-deploy.sh   # (如果有的话)

# 或者手动:
xcodebuild -project GhostPepper.xcodeproj -scheme GhostPepper \
  -configuration Release -derivedDataPath ./build-release \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build

# 看 app 日志
cat ~/Library/Application\ Support/GhostPepper/debug-log.json | tail
```

## 决策红灯

碰这些事前必须问用户:

- 上 App Store 发版 / 改 bundle id / 改签名证书
- 引入新的网络依赖
- 改默认 ASR / LLM 模型(影响首次下载体积)
- 删除 / 重命名核心模块
- 修改 git history / force push
- 升级 macOS 最低版本要求

## 项目演变史

详细见 git history + `docs/RESEARCH.md`。简要时间线:

- 2026-05-30: 从 ghost-pepper fork 起步,裁剪 ~12000 行(会议/QA/PepperChat/Lab 等)
- 2026-05-30~31: 模型矩阵反复调整(whisper-small → Qwen3-ASR → large-v3-turbo;Qwen 0.8B → 2B → 4B)
- 2026-05-31: 经过两次 "反对 reactive 补丁" 反馈,转向 systemic 方案
- 2026-06-01: 完成 deep-research 驱动的 Typeless 调研,基于真实信息重构 cleanup prompt
- 2026-06-01: 发布前清理(删上游 Matt 资产、Sparkle、SF Symbol 占位图标)
