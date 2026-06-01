import AppKit

class SoundEffects {
    private let startSound: NSSound?
    private let stopSound: NSSound?
    private let completionSound: NSSound?
    private let isEnabled: () -> Bool
    private let startPlayer: () -> Void
    private let stopPlayer: () -> Void
    private let completionPlayer: () -> Void

    init(
        isEnabled: @escaping () -> Bool = { true },
        startPlayer: (() -> Void)? = nil,
        stopPlayer: (() -> Void)? = nil,
        completionPlayer: (() -> Void)? = nil
    ) {
        startSound = NSSound(named: "Tink")
        stopSound = NSSound(named: "Pop")
        // 移植自 voicetyper:转写完成并粘贴后的第三段音效(Glass),给出明确的"已输入"反馈
        completionSound = NSSound(named: "Glass")
        self.isEnabled = isEnabled
        self.startPlayer = startPlayer ?? { [weak startSound] in
            startSound?.stop()
            startSound?.play()
        }
        self.stopPlayer = stopPlayer ?? { [weak stopSound] in
            stopSound?.stop()
            stopSound?.play()
        }
        self.completionPlayer = completionPlayer ?? { [weak completionSound] in
            completionSound?.stop()
            completionSound?.play()
        }
    }

    func playStart() {
        guard isEnabled() else { return }
        startPlayer()
    }

    func playStop() {
        guard isEnabled() else { return }
        stopPlayer()
    }

    func playCompletion() {
        guard isEnabled() else { return }
        completionPlayer()
    }
}
