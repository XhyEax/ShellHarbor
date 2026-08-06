@preconcurrency import SwiftTerm
import SwiftUI
import UIKit

enum MobileTerminalFont: String, CaseIterable, Identifiable {
    case dejaVuSansMono = "DejaVu Sans Mono"
    case ptMono = "PT Mono"
    case sourceCodeProMedium = "Source Code Pro Medium"
    case ubuntuMono = "Ubuntu Mono"
    case courierNew = "Courier New"
    case cascadiaCode = "Cascadia Code"
    case firaCode = "Fira Code"
    case jetBrainsMono = "JetBrains Mono"
    case meslo = "Meslo"

    var id: String { rawValue }

    private var fontNames: [String] {
        switch self {
        case .dejaVuSansMono: ["DejaVuSansMono", rawValue]
        case .ptMono: ["PTMono-Regular", rawValue]
        case .sourceCodeProMedium: ["SourceCodePro-Medium", rawValue]
        case .ubuntuMono: ["UbuntuMono-Regular", rawValue]
        case .courierNew: ["CourierNewPSMT", rawValue]
        case .cascadiaCode: ["CascadiaCode-Regular", rawValue]
        case .firaCode: ["FiraCode-Regular", rawValue]
        case .jetBrainsMono: ["JetBrainsMono-Regular", rawValue]
        case .meslo: ["MesloLGM-Regular", "MesloLGMDZ-Regular", rawValue]
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        for name in fontNames {
            if let font = UIFont(name: name, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum MobileTerminalTheme: String, CaseIterable, Identifiable {
    case night
    case graphite
    case solarizedDark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .night: "夜间"
        case .graphite: "石墨"
        case .solarizedDark: "Solarized Dark"
        case .light: "浅色"
        }
    }

    var colorScheme: ColorScheme { self == .light ? .light : .dark }

    fileprivate var palette: MobileTerminalPalette {
        switch self {
        case .night:
            MobileTerminalPalette(
                background: 0x090C14, foreground: 0xDCE3F0, cursor: 0x65A8FF,
                ansi: [
                    0x1B2230, 0xFF6B72, 0x54D68C, 0xFFD166,
                    0x65A8FF, 0xC792EA, 0x4DD7E5, 0xDCE3F0,
                    0x5C667A, 0xFF8B91, 0x76E6A5, 0xFFE08A,
                    0x8BC0FF, 0xDBA8F2, 0x76E7F0, 0xFFFFFF
                ]
            )
        case .graphite:
            MobileTerminalPalette(
                background: 0x171717, foreground: 0xE5E5E5, cursor: 0xF5F5F5,
                ansi: [
                    0x262626, 0xE06C75, 0x98C379, 0xE5C07B,
                    0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDCDC,
                    0x5C6370, 0xFF7A85, 0xB4E88D, 0xFFD68A,
                    0x80C7FF, 0xDFA1F2, 0x72D6E0, 0xFFFFFF
                ]
            )
        case .solarizedDark:
            MobileTerminalPalette(
                background: 0x002B36, foreground: 0x93A1A1, cursor: 0x2AA198,
                ansi: [
                    0x073642, 0xDC322F, 0x859900, 0xB58900,
                    0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                    0x586E75, 0xCB4B16, 0x586E75, 0x657B83,
                    0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
                ]
            )
        case .light:
            MobileTerminalPalette(
                background: 0xF7F8FA, foreground: 0x20242C, cursor: 0x2869C8,
                ansi: [
                    0x20242C, 0xC92A35, 0x1A7F45, 0x9A6700,
                    0x2869C8, 0x8250DF, 0x087E8B, 0xD8DEE8,
                    0x57606A, 0xE5534B, 0x2DA44E, 0xBF8700,
                    0x4184E4, 0xA475F9, 0x1B9AAA, 0xFFFFFF
                ]
            )
        }
    }
}

enum MobileTerminalFontSizeSettings {
    static let defaultSize = 16.0
    static let allowedSizes = 8.0...32.0

    static func normalized(_ size: Double) -> Double {
        min(max(size, allowedSizes.lowerBound), allowedSizes.upperBound)
    }
}

enum MobileTerminalScrollbackSettings {
    static let defaultLines = 100_000
    static let allowedLines = 1_000...1_000_000

    static func normalized(_ lines: Int) -> Int {
        min(max(lines, allowedLines.lowerBound), allowedLines.upperBound)
    }
}

private struct MobileTerminalPalette {
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let ansi: [UInt32]
}

private final class MobileTerminalNativeView: TerminalView, UIGestureRecognizerDelegate {
    private let hiddenKeyboardView = UIView(frame: .zero)
    private var remoteScrollGesture: UIPanGestureRecognizer?
    private var remoteUsesAlternateScreen = false
    private var interactionSequenceTail = ""

    override func layoutSubviews() {
        // SwiftUI briefly gives a retained terminal an almost-zero frame when
        // navigating away or switching workspace modes. Letting SwiftTerm
        // process that transient layout permanently reflows its grid to only
        // a few columns before the real frame returns.
        guard bounds.width >= 120, bounds.height >= 60 else { return }
        super.layoutSubviews()
    }

    override func mouseModeChanged(source: SwiftTerm.Terminal) {
        synchronizeRemoteScrollGesture()
    }

    func acceptRemoteOutput(_ bytes: [UInt8]) {
        feed(byteArray: bytes[...])
        trackAlternateScreen(in: bytes)
        synchronizeRemoteScrollGesture()
    }

    func resetRemoteInteractionState() {
        remoteUsesAlternateScreen = false
        interactionSequenceTail = ""
        let resetModes = Array(
            "\u{1B}[?47l\u{1B}[?1047l\u{1B}[?1049l\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l".utf8
        )
        feed(byteArray: resetModes[...])
        synchronizeRemoteScrollGesture()
    }

    private func synchronizeRemoteScrollGesture() {
        let shouldReport = getTerminal().mouseMode != .off
        if shouldReport {
            guard remoteScrollGesture == nil else { return }
            let gesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(reportRemoteScroll(_:))
            )
            gesture.delegate = self
            gesture.maximumNumberOfTouches = 1
            addGestureRecognizer(gesture)
            remoteScrollGesture = gesture
        } else if let remoteScrollGesture {
            removeGestureRecognizer(remoteScrollGesture)
            self.remoteScrollGesture = nil
        }
    }

    private func trackAlternateScreen(in bytes: [UInt8]) {
        let chunk = String(decoding: bytes, as: UTF8.self)
        let text = interactionSequenceTail + chunk
        var changes: [(offset: Int, enabled: Bool)] = []
        for mode in ["47", "1047", "1049"] {
            for (suffix, enabled) in [("h", true), ("l", false)] {
                let token = "\u{1B}[?\(mode)\(suffix)"
                var search = text.startIndex..<text.endIndex
                while let range = text.range(of: token, range: search) {
                    changes.append((text.distance(from: text.startIndex, to: range.lowerBound), enabled))
                    search = range.upperBound..<text.endIndex
                }
            }
        }
        for change in changes.sorted(by: { $0.offset < $1.offset }) {
            remoteUsesAlternateScreen = change.enabled
        }
        interactionSequenceTail = String(text.suffix(24))
    }

    @objc private func reportRemoteScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let translation = gesture.translation(in: self)
        let stepHeight: CGFloat = 18
        let steps = min(16, Int(abs(translation.y) / stepHeight))
        guard steps > 0 else { return }
        let terminal = getTerminal()
        guard terminal.mouseMode != .off else { return }
        let button = translation.y > 0 ? 64 : 65
        let x = max(0, terminal.cols / 2)
        let y = max(0, terminal.rows / 2)
        for _ in 0..<steps {
            terminal.sendEvent(buttonFlags: button, x: x, y: y)
        }
        gesture.setTranslation(.zero, in: self)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let isSelectingForCopy = gestureRecognizers?.contains { gesture in
            guard gesture is UILongPressGestureRecognizer else { return false }
            return gesture.state == .began || gesture.state == .changed
        } ?? false
        inputView = isSelectingForCopy ? hiddenKeyboardView : nil
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { reloadInputViews() }
        return becameFirstResponder
    }
}

struct MobileTerminalView: UIViewRepresentable {
    let controller: MobileSSHController
    @AppStorage("mobileTerminalFont") private var fontName = MobileTerminalFont.dejaVuSansMono.rawValue
    @AppStorage("mobileTerminalFontSize") private var fontSize =
        MobileTerminalFontSizeSettings.defaultSize
    @AppStorage("mobileTerminalTheme") private var themeName = MobileTerminalTheme.night.rawValue
    @AppStorage("mobileTerminalScrollbackLines") private var scrollbackLines = MobileTerminalScrollbackSettings.defaultLines

    private var terminalFont: UIFont {
        (MobileTerminalFont(rawValue: fontName) ?? .dejaVuSansMono)
            .uiFont(size: CGFloat(MobileTerminalFontSizeSettings.normalized(fontSize)))
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = MobileTerminalNativeView(frame: .zero, font: terminalFont)
        view.inputAccessoryView = nil
        view.showsVerticalScrollIndicator = true
        view.verticalScrollIndicatorInsets = .zero
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.getTerminal().setCursorStyle(.steadyBlock)
        applyAppearance(to: view)
        context.coordinator.appearance = appearance
        view.terminalDelegate = context.coordinator
        context.coordinator.terminal = view
        context.coordinator.lastClearRequestID = controller.clearRequestID
        context.coordinator.lastSearchRequestID = controller.searchRequestID
        context.coordinator.lastKeyboardToggleRequestID = controller.keyboardToggleRequestID
        controller.connect { [weak view] bytes in
            view?.acceptRemoteOutput(bytes)
        }
        // connect() replays persisted output synchronously before starting the
        // live transport. Historical DECSET sequences must not authorize new
        // input; only sequences received from the live session may do so.
        view.resetRemoteInteractionState()
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.controller = controller
        if uiView.font.fontName != terminalFont.fontName || uiView.font.pointSize != terminalFont.pointSize {
            uiView.font = terminalFont
        }
        if context.coordinator.appearance != appearance {
            applyAppearance(to: uiView)
            context.coordinator.appearance = appearance
        }
        if context.coordinator.lastClearRequestID != controller.clearRequestID {
            context.coordinator.lastClearRequestID = controller.clearRequestID
            uiView.getTerminal().resetToInitialState()
            uiView.clearSearch()
            uiView.scroll(toPosition: 1)
            uiView.setNeedsLayout()
            uiView.setNeedsDisplay()
        }
        if context.coordinator.lastSearchRequestID != controller.searchRequestID {
            context.coordinator.lastSearchRequestID = controller.searchRequestID
            if controller.shouldClearSearch || controller.searchTerm.isEmpty {
                uiView.clearSearch()
                Task { @MainActor in controller.updateSearchResult(found: false) }
            } else {
                let found: Bool
                if controller.searchForward {
                    found = uiView.findNext(controller.searchTerm)
                } else {
                    found = uiView.findPrevious(controller.searchTerm)
                }
                Task { @MainActor in controller.updateSearchResult(found: found) }
            }
            uiView.setNeedsDisplay()
        }
        if context.coordinator.lastKeyboardToggleRequestID != controller.keyboardToggleRequestID {
            context.coordinator.lastKeyboardToggleRequestID = controller.keyboardToggleRequestID
            if uiView.isFirstResponder {
                _ = uiView.resignFirstResponder()
            } else {
                _ = uiView.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.terminal = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    private func applyAppearance(to view: TerminalView) {
        let theme = MobileTerminalTheme(rawValue: themeName) ?? .night
        let palette = theme.palette
        view.backgroundColor = UIColor(hex: palette.background)
        view.nativeBackgroundColor = UIColor(hex: palette.background)
        view.nativeForegroundColor = UIColor(hex: palette.foreground)
        view.caretColor = UIColor(hex: palette.cursor)
        view.installColors(palette.ansi.map(SwiftTerm.Color.init(hexRGB:)))
        view.getTerminal().changeHistorySize(
            MobileTerminalScrollbackSettings.normalized(scrollbackLines)
        )
        view.setNeedsDisplay()
    }

    private var appearance: Appearance {
        Appearance(
            themeName: themeName,
            scrollbackLines: MobileTerminalScrollbackSettings.normalized(scrollbackLines)
        )
    }

    fileprivate struct Appearance: Equatable {
        let themeName: String
        let scrollbackLines: Int
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        var controller: MobileSSHController
        weak var terminal: TerminalView?
        var lastClearRequestID: UUID?
        var lastSearchRequestID: UUID?
        var lastKeyboardToggleRequestID: UUID?
        fileprivate var appearance: Appearance?

        init(controller: MobileSSHController) {
            self.controller = controller
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm can briefly report a nearly zero-sized grid while a
            // restored terminal is being mounted. Sending that transient size
            // to the already reconnected PTY makes the remote shell wrap every
            // few characters until the next resize event.
            guard newCols >= 20, newRows >= 4,
                  source.bounds.width >= 120, source.bounds.height >= 60 else {
                return
            }
            controller.resize(
                cols: newCols,
                rows: newRows,
                pixelWidth: Int(source.bounds.width * source.contentScaleFactor),
                pixelHeight: Int(source.bounds.height * source.contentScaleFactor)
            )
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            controller.title = title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            controller.lastDirectory = directory
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            // Color-query replies (OSC 4/10/11/12) can arrive after a short-
            // lived remote probe has already timed out. Bash then interprets
            // the late `index;rgb:...` payload as commands. A network-backed
            // terminal cannot guarantee the synchronous response timing that
            // local PTYs provide, so deliberately report these queries as
            // unsupported instead of injecting stale replies into the shell.
            guard !Self.isColorQueryResponse(data) else { return }
            controller.send(data)
        }

        private static func isColorQueryResponse(_ data: ArraySlice<UInt8>) -> Bool {
            let bytes = Array(data)
            let payloadStart: Int
            if bytes.starts(with: [0x1B, 0x5D]) {
                payloadStart = 2
            } else if bytes.first == 0x9D {
                payloadStart = 1
            } else {
                return false
            }
            guard payloadStart < bytes.count else { return false }
            let payload = String(decoding: bytes[payloadStart...], as: UTF8.self)
            guard payload.contains(";rgb:") else { return false }
            let code = payload.prefix { $0 != ";" }
            return code == "4" || code == "10" || code == "11" || code == "12"
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
            UIApplication.shared.open(url)
        }

        func bell(source: TerminalView) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let value = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = value
            }
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private extension SwiftTerm.Color {
    convenience init(hexRGB: UInt32) {
        self.init(
            red: UInt16((hexRGB >> 16) & 0xFF) * 257,
            green: UInt16((hexRGB >> 8) & 0xFF) * 257,
            blue: UInt16(hexRGB & 0xFF) * 257
        )
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
