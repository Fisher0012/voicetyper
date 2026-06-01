import Foundation

/// 用户成功 paste 的转写历史 + 高频术语提取。注入到 ASR initialPrompt 和 LLM cleanup prompt,
/// 让 VoiceTyper 越用越准 — 不再硬编码"HTTPS/React",而是从你实际说的内容里学。
final class TermHistoryStore {
    static let shared = TermHistoryStore()

    private let queue = DispatchQueue(label: "GhostPepper.TermHistoryStore.queue")
    private let storeURL: URL
    private let maxEntries = 200  // 限制历史规模,防止文件无限增长

    // 缓存提取结果,避免每次录音前都全量扫描历史(可能积累上千词)
    private var cachedTerms: (englishTerms: [String], chineseTerms: [String])?
    private var cacheDirty = true

    /// 用户自定义术语文件路径。用户可以手动编辑这个文件,每行一个术语,优先注入到字典最前面。
    /// 解决"ASR 一直听错的词,字典永远学不到正确版本"的根本 bug — 字典自学习只能强化已经对的词,
    /// 修不了一直错的词。custom terms 让用户直接预设常用术语,不依赖 ASR 先听对。
    private let customTermsURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("GhostPepper", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        self.storeURL = appDir.appendingPathComponent("term-history.json")
        self.customTermsURL = appDir.appendingPathComponent("custom-terms.txt")
    }

    /// 读自定义术语(用户可手动编辑 custom-terms.txt,每行一个)
    private func loadCustomTerms() -> [String] {
        guard let data = try? Data(contentsOf: customTermsURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// 记录一次成功 paste 的最终文本。在 AppState.processRecordingResult 的 paste 之后调用。
    func record(text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count >= 2 else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var entries = self.loadEntries()
            entries.append(cleaned)
            if entries.count > self.maxEntries {
                entries = Array(entries.suffix(self.maxEntries))
            }
            self.saveEntries(entries)
            self.cacheDirty = true
        }
    }

    /// 提取高频术语。返回 (英文术语, 中文实体词)。
    func extractTerms() -> (englishTerms: [String], chineseTerms: [String]) {
        return queue.sync {
            if let cached = cachedTerms, !cacheDirty {
                return cached
            }
            let entries = loadEntries()
            let result = Self.extract(from: entries)
            cachedTerms = result
            cacheDirty = false
            return result
        }
    }

    /// 生成可注入到 LLM cleanup prompt 的紧凑字符串。
    /// 优先级: custom-terms.txt(用户预设)> 历史高频术语(自学习)。custom 在最前面让 LLM 优先匹配。
    func promptInjection(maxCharacters: Int = 600) -> String {
        let custom = loadCustomTerms()
        let (en, zh) = extractTerms()
        var parts: [String] = []
        if !custom.isEmpty {
            parts.append("CRITICAL — user's defined terms (always prefer these when an ASR-misheard word sounds similar): " + custom.joined(separator: ", "))
        }
        if !en.isEmpty {
            parts.append("Frequent English terms: " + en.joined(separator: ", "))
        }
        if !zh.isEmpty {
            parts.append("常用中文词汇: " + zh.joined(separator: "、"))
        }
        let joined = parts.joined(separator: "。 ")
        if joined.count <= maxCharacters { return joined }
        return String(joined.prefix(maxCharacters))
    }

    // MARK: - Internals

    private func loadEntries() -> [String] {
        guard let data = try? Data(contentsOf: storeURL),
              let entries = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return entries
    }

    private func saveEntries(_ entries: [String]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// 从历史文本里抽取高频术语。
    /// - 英文:首字母大写词/全大写缩写/含数字的标识符,频次≥2 取 top 40
    /// - 中文:2-4 字连续汉字,频次≥3 取 top 30
    static func extract(from entries: [String]) -> (englishTerms: [String], chineseTerms: [String]) {
        let allText = entries.joined(separator: "\n")
        let englishRegex = try! NSRegularExpression(
            pattern: "(?:[A-Z][a-zA-Z0-9]{2,}|[A-Z]{2,}|[a-zA-Z]+[0-9]+|[a-zA-Z]+\\.[a-zA-Z]+)"
        )
        let chineseRegex = try! NSRegularExpression(pattern: "[\\u4e00-\\u9fff]{2,4}")
        let fullRange = NSRange(allText.startIndex..., in: allText)

        var englishCounts: [String: Int] = [:]
        for match in englishRegex.matches(in: allText, range: fullRange) {
            if let r = Range(match.range, in: allText) {
                englishCounts[String(allText[r]), default: 0] += 1
            }
        }
        var chineseCounts: [String: Int] = [:]
        for match in chineseRegex.matches(in: allText, range: fullRange) {
            if let r = Range(match.range, in: allText) {
                chineseCounts[String(allText[r]), default: 0] += 1
            }
        }
        let topEnglish = englishCounts
            .filter { $0.value >= 2 && $0.key.count >= 3 }
            .sorted { ($0.value, $0.key.count) > ($1.value, $1.key.count) }
            .prefix(40)
            .map { $0.key }
        let topChinese = chineseCounts
            .filter { $0.value >= 3 }
            .sorted { ($0.value, $0.key.count) > ($1.value, $1.key.count) }
            .prefix(30)
            .map { $0.key }
        return (Array(topEnglish), Array(topChinese))
    }
}
