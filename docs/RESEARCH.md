# Typeless 真实实现调研报告

> **本文档基于 2026-06-01 对 Typeless(typeless.app)的多源公开信息调研。**
> 所有声明均有引用来源,未引用的部分明确标注"未公开"。
>
> 这份调研是 VoiceTyper 关键架构决策的依据 — 包括为什么我们的 cleanup prompt 是这样的设计、为什么我们选 Qwen 4B 而非更大、为什么没做某些功能。

## 调研背景

VoiceTyper 早期开发阶段(2026-05-30~31),我反复用"补丁式"思路追赶 Typeless 体验,但效果不理想。Donnie 两次明确指出:**"不能靠猜测和补丁,应该先了解 Typeless 的真实实现逻辑"**。

于是做了一次系统性的多源公开信息调研(使用 deep-research workflow:5 个并行 WebSearch 角度 + 抓取 top 15 sources + 3-vote 对抗式验证)。

---

## TL;DR — 三个反转事实

1. **Typeless 不是本地架构,是云端混合**
   - 隐私政策原文:"audio inputs ... processed in real time on our **cloud servers**, immediately discarded"
   - 第三方逆向(2025-11)显示音频被路由到 AWS us-east-2
   - "on-device" 营销话术仅指**历史存储位置**(本地保存你过往转写),不是音频处理位置

2. **完全不公开技术细节**
   - ASR 模型(Whisper? 自研?)未披露
   - LLM 模型厂商(GPT-4 / Claude / Gemini?)未披露
   - 是否用 WhisperKit / MLX / CoreML 未披露
   - 没有公开延迟数字

3. **它的差异化是 LLM 后处理产品化深度,不是模型本身**
   - 关键能力是 prompt 工程 + 上下文感知,不靠"更大模型"
   - 营销话术 "AI understands context, fixes grammar, and adapts to your style"

---

## 架构与模型

### 处理位置:云端 + 本地历史

**官方隐私政策**(typeless.com/privacy):
> "Your audio inputs and contextual information are processed in real time on our cloud servers and immediately discarded once the transcription result is returned to your local device."

> "We may share your data with third-party LLMs in order to provide certain features. Your data is never used to train these services and is configured for zero retention by the providers."

**数据控制页**:
> "Transcription is performed on the cloud to ensure the highest accuracy and low-latency performance."

**第三方分析**:2025-11 @medmuspg 在 X 上的逆向报告显示音频被路由到 AWS us-east-2(Ohio)。

**结论**:Typeless 是 **cloud-only**,无离线模式。"on-device history storage" 仅指本地保存历史转写,不是处理位置。

### 模型选型:完全保密

定价页(typeless.com/pricing)、Product Hunt 页、release notes 均无任何 ASR / LLM 模型名称、版本号、加速框架(MLX / CoreML)的提及。营销文案只说"AI understands context",没有任何架构细节。

### 隐私话术 vs 处理事实

定价页列出 5 条隐私声明:
- "Zero cloud data retention"
- "Never trained on your data"
- "On-device history storage"
- HIPAA 合规(2026-03 宣布)
- GDPR 合规

**这些都是数据策略,不是处理位置声明**。Typeless 实际是云端处理,但承诺零保留 + 不训练。这种表述容易被误读为"本地处理",但严格来讲并不矛盾(只是营销层面有歧义)。

---

## 识别精度策略

### LLM 后处理是核心差异化

Typeless 的主要能力(release notes + Product Hunt + 多评测一致描述):

1. **自动删填充词**:"um", "uh"
2. **消除重复**
3. **识别中途自我纠正,保留最终意图**:核心 example —
   > "Do you want to grab coffee, actually boba?" → "Do you want to grab boba?"
4. **按目标 app 自适应语气**:Gmail 写邮件格式、Slack 写聊天回复
5. **自动格式化**:列表 / 项目符号 / 语法
6. **按用户风格调整**:学习用户写作风格

用户反馈原话:"transforms my fragmented thoughts into well-structured text" "captures my voice perfectly"。

### 个人词典(Personal Dictionary)

**Product Hunt 原文**:
> "Personal dictionary learns your unique vocabulary—names, terms, brands—and never forgets"

- 免费版与 Pro 版都有此功能
- Pro 解锁无限词条
- 用户**手动添加**专名/术语/品牌
- "learns" 主要指**用户加进字典后持久化**,而非从纠错中自主学习(后者未见明确证据)

### 中英混说 / 多语言

- 支持 100+ 语言(简体 + 繁体中文均支持)
- 同一段内可混说多语言,自动检测
- 独立翻译模式(macOS v0.7.0+,快捷键 **fn+Shift**)— 口述源语言实时翻译为目标语言

用户原话:"speaking in Chinese... already automatically translated my speech into English"

### 上下文一致性(同概念多变体统一)

**未在官方文档中明确说明**,但产品体验中显然存在(从用户评测推测)。这是 VoiceTyper 决定明确写入 prompt 的"SAME-CONCEPT CONSISTENCY"规则的依据。

### 自我纠正实现

**调研结论(置信度 medium)**:基于 **LLM 推断意图**,而非显式信号词或硬匹配。

证据:
- Product Hunt 例子 "coffee, actually boba" → "boba" 显示系统理解 "actually" 这类自然语言信号
- 多个评测描述为 "keeps only your final intended message"
- 这是 LLM 后处理的产物,不依赖固定关键词列表

**Typeless 未公开 prompt 设计细节**,但行为强烈暗示 LLM 推断。这是 VoiceTyper 决定**撤回 regex 硬匹配自我纠正**、改用 LLM 推断的依据。

---

## 交互 / 体验细节

### 单段录音上限

**6 分钟**,5 分钟时发警告,超时自动保存当前段到 History。

(typeless.com/help/troubleshooting/dictation-limit)

### 快捷键

具体快捷键完整规格**未公开披露**。已知:
- 普通听写模式有快捷键(具体未公开)
- 翻译模式:**fn+Shift**(macOS v0.7.0+)

### 浮层 / 动画

具体浮层设计、动画、音量波纹**未公开**。

### 延迟

具体延迟数字**未公开**。用户描述为"快"但无量化。

---

## VoiceTyper vs Typeless 对照表

| 维度 | Typeless | VoiceTyper | 差距评估 |
|---|---|---|---|
| 隐私 / 本地化 | 云端,只是话术好 | 100% 本地 (whisper-large-v3-turbo + Qwen 4B) | **VoiceTyper 领先** ✅ |
| ASR 模型 | 未公开,可能云端 Whisper-large | whisper-large-v3-turbo 本地 | 不明,理论相当 |
| LLM 后处理 | 云端大 LLM + 深度产品化 prompt | Qwen 4B 本地 + 产品化 prompt | **小**(模型规模)/ **大**(prompt 设计成熟度) |
| 自我纠正 | LLM 推断意图 | LLM 推断意图(2026-06-01 改) | 已对齐 |
| 按目标 app 切语气 | 有 | 无 | 大 |
| 风格学习 | 有 | 无 | 大 |
| 格式化 | 深度自动 | prompt 通用规则 | 小 |
| 多语言 | 100+ + 翻译模式 | 多语言 | 中 |
| 个人词典 | 词典 UI 增删管理 + 自学习 | custom-terms.txt 手动编辑 | 小(功能上)/ **大**(UX 上) |
| VAD | 未公开 | 实现了静音 2s 自动停 | VoiceTyper 领先 |
| 单段时长上限 | 6 分钟 | 无 | VoiceTyper 领先 |
| 账号 / 订阅 | 必需 | 无 | VoiceTyper 领先 |

---

## 基于调研的 VoiceTyper 设计决策

### 1. 撤回 regex 硬匹配自我纠正

**调研依据**:Typeless 是 LLM 推断意图,不是关键词列表。

**改动**:`GhostPepper/Cleanup/TextCleaner.swift` 不再调用 `applyChineseRestartCorrection()`,改由 Qwen 4B prompt 引导推断("coffee, actually boba" 例子)。

### 2. 重写 cleanup prompt 为产品化任务

**调研依据**:Typeless 的差异化在 prompt 工程产品化深度,不在模型本身。

**改动**:从"11 条 FIRM RULES"改成"角色 + 任务优先级"。详见 `TextCleaner.defaultPrompt`。

### 3. 保留用户领域词典

**调研依据**:Typeless 也有 Personal Dictionary,**用户手动添加**模式。我们的 `custom-terms.txt` 是同等概念。

### 4. 不做云端 ASR

**调研依据**:Typeless 用云端 ASR 换精度,我们坚守 100% 本地。这是产品定位差异,不是技术劣势。

### 5. 不做"按目标 app 切语气"(暂时)

**调研依据**:Typeless 有,但 Donnie 主要场景是 Vibe Coding(Cursor / Claude Code),单一上下文,价值有限。

### 6. 不做翻译模式(暂时)

**调研依据**:独立需求,与"语音输入"主功能正交。可后续做。

---

## 引用来源

调研覆盖以下来源(均为公开可访问):

**Typeless 官方**:
- https://typeless.com/privacy
- https://typeless.com/data-controls
- https://typeless.com/pricing
- https://typeless.com/help/release-notes/macos
- https://typeless.com/help/release-notes/macos/translation-mode
- https://typeless.com/help/troubleshooting/dictation-limit

**Product Hunt**:
- https://www.producthunt.com/products/typeless-2
- https://www.producthunt.com/p/typeless-2/we-are-launching-typeless-for-ios-ask-me-anything

**第三方对比 / 评测**:
- https://www.getvoibe.com/resources/typeless-privacy-issues/
- https://www.getvoibe.com/resources/typeless-vs-superwhisper/
- https://www.getvoibe.com/resources/typeless-vs-wispr-flow/
- https://www.getvoibe.com/blog/typeless-alternatives/
- https://freeaio.com/typeless-pricing/
- https://chatgate.ai/post/typeless-2/

**X / 社区**:
- @medmuspg 2025-11 逆向报告(AWS us-east-2)

---

## 这份调研的局限

- Typeless 的具体 prompt、模型选型、内部架构属于商业秘密,**永远无法 100% 知道**
- 调研基于公开信息,行为推测有解释空间
- 一些条目(如延迟数字、快捷键完整规格)在公开渠道**没有信息**
- 调研日期 2026-06-01,Typeless 持续演进,以后会有偏差

VoiceTyper 的目标不是 1:1 复刻 Typeless,是**在 100% 本地约束下尽力逼近其核心体验**。这份调研为方向感提供事实依据,不是产品规格书。
