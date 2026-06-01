import Foundation

/// 质量评测集。每条记录 (ASR 原始输出, 期望的清理结果)。
///
/// 用法:
/// 1. 用户每次报告"这次识别错了",把 raw_asr + expected 加进 cases
/// 2. 每次升级模型 / 改 prompt,跑 QualityEvalRunner.run() 看通过率
/// 3. 不再"凭感觉"判断是否真的优化了 — 数字说话
///
/// 这是 systemic 方案的关键:**用评测驱动优化**,而不是 "用户报错→打补丁→破坏其他场景→用户再报错" 的循环。
struct QualityEvalCase: Codable {
    let id: String
    let rawASR: String          // ASR 原始输出(可能含错误)
    let expectedClean: String   // 期望的最终清理结果
    let note: String?           // 这条 case 的来源/含义说明
}

enum QualityEvalCases {
    /// 截至目前用户报告过的、可作为回归测试的真实 case。
    /// 新错误 ⇒ append 一条;升级前先跑这个列表确保不回退。
    static let cases: [QualityEvalCase] = [
        QualityEvalCase(
            id: "self-correction-long",
            rawASR: "再次测试。整体功能验证完成后，无需重启，权限将实时生效。试一下你是否能准确了解我说话的关键内容。比如我说错了，我会把前面一段删掉。现在把前面这段删掉，我重新说。我只留现在说的话。这句话就是：弹出对话框了吗？",
            expectedClean: "弹出对话框了吗？",
            note: "用户实测的自我纠正(typeless 关键体验)"
        ),
        QualityEvalCase(
            id: "self-correction-short",
            rawASR: "用户登录失败的时候返回 401，不对，重来，应该返回 403",
            expectedClean: "用户登录失败的时候应该返回 403。",
            note: "短句自我纠正"
        ),
        QualityEvalCase(
            id: "trad-to-simp",
            rawASR: "AI 財經創作站",
            expectedClean: "AI 财经创作站",
            note: "繁→简强制(whisper-small 多语言常输出繁体)"
        ),
        QualityEvalCase(
            id: "term-typeless",
            rawASR: "我们继续推进对 Tablet 的质量逼近",
            expectedClean: "我们继续推进对 Typeless 的质量逼近",
            note: "上下文术语推断:讨论语音转写工具时 Tablet→Typeless"
        ),
        QualityEvalCase(
            id: "term-ai-not-ar",
            rawASR: "AR 财经创作站",
            expectedClean: "AI 财经创作站",
            note: "单字母音近混淆:AI/AR 在'财经创作'语境里 AI 显然合理"
        ),
        QualityEvalCase(
            id: "term-zhong-ying-wen",
            rawASR: "我会测试诸英文",
            expectedClean: "我会测试中英文",
            note: "短促音误听:诸英文→中英文(测试 mixed-language 场景)"
        ),
        QualityEvalCase(
            id: "boundary-smalland",
            rawASR: "用 Whisper Smalland Apple Store is open",
            expectedClean: "用 Whisper Small。And Apple Store is open。",
            note: "英文词边界粘连切分"
        ),
        QualityEvalCase(
            id: "fillers-zh",
            rawASR: "嗯，那个，我们明天下午三点开会",
            expectedClean: "我们明天下午三点开会。",
            note: "中文填充词清理"
        ),
        QualityEvalCase(
            id: "punctuation-runon",
            rawASR: "先测试一下速度科比布莱恩特是NBA球星这个速度好像还可以",
            expectedClean: "先测试一下速度。科比·布莱恩特是 NBA 球星,这个速度好像还可以。",
            note: "长串无断句 → 加正确标点 + 中英空格"
        ),
    ]
}
