import Cocoa
import CoreGraphics

/// 增量(progressive)文字注入。用 CGEvent + keyboardSetUnicodeString 把文字一段段插入到当前焦点位置,
/// 模拟"打字感"——LLM 流式生成的每个 token 来到都立即可见,达到 Typeless 那种"边想边出字"的体感。
///
/// 与 TextPaster 的 Cmd+V 区别:
/// - TextPaster:走剪贴板 + Cmd+V,**一次性**粘整段(适合 final paste)
/// - TextStreamer:走 unicode keystroke,**增量**插入(适合 streaming 中间状态)
///
/// 副作用与权衡:
/// - 期间用户切换焦点会导致后续字符落到错误窗口(Typeless 也有这个问题,实践中可接受)
/// - unicode keystroke 在标准文本输入控件上稳定;某些 Electron app / 终端模拟器表现可能不同
/// - 不污染剪贴板(没用 NSPasteboard)
final class TextStreamer {
    private let source: CGEventSource?

    init() {
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// 插入一段文本到当前焦点位置(unicode 注入,不走剪贴板)。
    /// 单次调用即一个 keyDown + keyUp 事件对,字符串作为 unicode payload。
    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            // keyDown
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                event.post(tap: .cghidEventTap)
            }
            // keyUp(配对发送防止系统认为按键卡住)
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
