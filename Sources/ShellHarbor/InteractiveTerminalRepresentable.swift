import AppKit
import SwiftUI
@preconcurrency import SwiftTerm

enum TerminalFilePasteDecoder {
    static func paths(from pasteboard: NSPasteboard) -> [String]? {
        let objectURLs = (
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
        ) ?? []
        if !objectURLs.isEmpty {
            return objectURLs.map(\.standardizedFileURL.path)
        }

        let fileURLStrings = pasteboard.pasteboardItems?.compactMap {
            $0.string(forType: .fileURL)
        } ?? []
        return paths(
            fileURLStrings: fileURLStrings,
            plainText: pasteboard.string(forType: .string)
        )
    }

    static func paths(
        fileURLStrings: [String],
        plainText: String?
    ) -> [String]? {
        let candidates: [String]
        if !fileURLStrings.isEmpty {
            candidates = fileURLStrings
        } else {
            candidates = plainText?
                .components(separatedBy: .newlines)
                .map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }
                .filter { !$0.isEmpty } ?? []
        }
        guard !candidates.isEmpty else { return nil }

        let urls = candidates.compactMap { raw -> URL? in
            guard
                let url = URL(string: raw),
                url.isFileURL
            else {
                return nil
            }
            return url
        }
        guard urls.count == candidates.count else { return nil }
        return urls.map(\.standardizedFileURL.path)
    }
}

struct InteractiveTerminalRepresentable: NSViewRepresentable {
    let controller: TerminalController
    let connectionToken: UUID
    let invocation: SSHInvocation?
    let theme: TerminalTheme

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, connectionToken: connectionToken)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view: LocalProcessTerminalView
        if let retained = controller.retainedTerminalView {
            view = retained
        } else {
            view = SteadyCursorTerminalView(frame: .zero)
            view.optionAsMetaKey = true
            view.allowMouseReporting = true
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.getTerminal().changeScrollback(
                controller.scrollbackLines
            )
            controller.retainTerminalView(view)
        }
        (view as? SteadyCursorTerminalView)?.restorationController =
            controller
        // Match the system wcwidth behavior used by tmux/screen. SwiftTerm's
        // wide default can move its cursor two cells while the remote PTY
        // moves one, which makes text appear out of order after Mosh redraws.
        view.getTerminal().options.regionalIndicatorWidth = .narrow
        view.font =
            NSFont(name: "NotoMonoForPowerline", size: 16) ??
            NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        view.processDelegate = controller.processDelegate
        applyTheme(theme, to: view)
        context.coordinator.terminalView = view
        context.coordinator.synchronize(
            view: view,
            connectionToken: connectionToken,
            invocation: invocation,
            theme: theme
        )
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        controller.retainTerminalView(view)
        context.coordinator.synchronize(
            view: view,
            connectionToken: connectionToken,
            invocation: invocation,
            theme: theme
        )
    }

    static func dismantleNSView(
        _ view: LocalProcessTerminalView,
        coordinator: Coordinator
    ) {
        // The controller retains both the terminal view and its process
        // delegate. Removing it from the selected hierarchy must not stop the
        // PTY or discard background termination events.
        coordinator.terminalView = nil
    }

    @MainActor
    final class Coordinator {
        let controller: TerminalController
        weak var terminalView: LocalProcessTerminalView?

        private var activeConnectionToken: UUID
        private var startedConnectionToken: UUID?
        private var lastDisconnectToken: UUID
        private var lastInterruptToken: UUID
        private var lastClearToken: UUID
        private var lastInputRequestID: UUID?
        private var lastTheme: TerminalTheme?

        init(controller: TerminalController, connectionToken: UUID) {
            self.controller = controller
            self.activeConnectionToken = connectionToken
            self.lastDisconnectToken = controller.disconnectToken
            self.lastInterruptToken = controller.interruptToken
            self.lastClearToken = controller.clearToken
            self.lastInputRequestID = controller.inputRequest?.id
        }

        func synchronize(
            view: LocalProcessTerminalView,
            connectionToken: UUID,
            invocation: SSHInvocation?,
            theme: TerminalTheme
        ) {
            if lastTheme != theme {
                lastTheme = theme
                applyTheme(theme, to: view)
            }
            if connectionToken != activeConnectionToken {
                if view.process.running {
                    view.terminate()
                }
                activeConnectionToken = connectionToken
                startedConnectionToken = nil
            }

            if controller.disconnectToken != lastDisconnectToken {
                lastDisconnectToken = controller.disconnectToken
                if view.process.running {
                    view.terminate()
                }
            }

            if controller.interruptToken != lastInterruptToken {
                lastInterruptToken = controller.interruptToken
                send([0x03], to: view)
            }

            if controller.clearToken != lastClearToken {
                lastClearToken = controller.clearToken
                (view as? SteadyCursorTerminalView)?
                    .clearLocalBufferPreservingCurrentLine()
            }

            if
                let request = controller.inputRequest,
                request.id != lastInputRequestID
            {
                lastInputRequestID = request.id
                send(Array(request.text.utf8), to: view)
                view.window?.makeFirstResponder(view)
            }

            guard
                startedConnectionToken != connectionToken,
                let invocation
            else { return }

            startedConnectionToken = connectionToken
            if view.process.running {
                controller.processStarted(for: connectionToken)
                controller.scheduleRestoredCommandIfNeeded(
                    in: view,
                    token: connectionToken
                )
                return
            }
            if let buffer = controller.consumeRestoredTerminalBuffer() {
                let replay = SessionRestorationStore.replayBuffer(buffer)
                view.feed(byteArray: Array(replay)[...])
            }
            var environment = invocation.environment
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            let environmentList = environment
                .map { "\($0.key)=\($0.value)" }
                .sorted()

            view.startProcess(
                executable: invocation.executableURL.path,
                args: invocation.arguments,
                environment: environmentList,
                execName: invocation.executableURL.lastPathComponent,
                currentDirectory: invocation.currentDirectory
            )
            controller.processStarted(for: connectionToken)
            controller.scheduleRestoredCommandIfNeeded(
                in: view,
                token: connectionToken
            )
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }

        private func send(_ bytes: [UInt8], to view: LocalProcessTerminalView) {
            guard view.process.running else { return }
            view.process.send(data: bytes[...])
        }

    }
}

/// Keeps the terminal caret visible without blinking. Remote programs can
/// request a cursor style through DECSCUSR, so blinking variants are converted
/// here instead of only changing the terminal's initial option.
final class SteadyCursorTerminalView: LocalProcessTerminalView {
    weak var restorationController: TerminalController?

    func insertFilePaths(_ paths: [String]) {
        let text = ShellPathInputFormatter.text(for: paths)
        guard !text.isEmpty else { return }
        send(source: self, data: Array(text.utf8)[...])
    }

    func showTerminalFindBar() {
        performFindPanelAction(
            findMenuItem(action: .showFindPanel)
        )
    }

    func findTerminalMatch(next: Bool) {
        performFindPanelAction(
            findMenuItem(action: next ? .next : .previous)
        )
    }

    /// Clears only SwiftTerm's local display and scrollback. The child
    /// process is intentionally not notified, so readline, SSH, tmux and
    /// remote shell state remain untouched.
    func clearLocalBufferPreservingCurrentLine() {
        scrollTo(row: Int.max, notifyAccessibility: false)
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let currentLine = terminal.getLine(row: cursor.y)?
            .translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: true
            ) ?? ""

        var restoration = "\u{1B}[3J\u{1B}[2J\u{1B}[H"
        restoration += currentLine + "\r"
        if cursor.x > 0 {
            restoration += "\u{1B}[\(cursor.x)C"
        }
        feed(text: restoration)
        setNeedsDisplay(bounds)
        restorationController?.terminalOutputDidChange()
    }

    override func send(
        source: SwiftTerm.TerminalView,
        data: ArraySlice<UInt8>
    ) {
        restorationController?.recordTerminalInput(Array(data))
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        restorationController?.terminalOutputDidChange(Array(slice))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let relevantModifiers = event.modifierFlags.intersection([
            .command, .shift, .option, .control
        ])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if
            relevantModifiers == .command,
            key == "f"
        {
            showTerminalFindBar()
            return true
        }
        if relevantModifiers == .command, key == "g" {
            findTerminalMatch(next: true)
            return true
        }
        if
            relevantModifiers == [.command, .shift],
            key == "g"
        {
            findTerminalMatch(next: false)
            return true
        }
        if
            relevantModifiers == .command,
            key == "k"
        {
            clearLocalBufferPreservingCurrentLine()
            return true
        }
        if
            relevantModifiers == .command,
            key == "v",
            let paths = TerminalFilePasteDecoder.paths(
                from: .general
            )
        {
            insertFilePaths(paths)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func findMenuItem(action: NSFindPanelAction) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        return item
    }

    override func cursorStyleChanged(
        source: SwiftTerm.Terminal,
        newStyle: CursorStyle
    ) {
        let steadyStyle: CursorStyle = switch newStyle {
        case .blinkBlock:
            .steadyBlock
        case .blinkUnderline:
            .steadyUnderline
        case .blinkBar:
            .steadyBar
        case .steadyBlock, .steadyUnderline, .steadyBar:
            newStyle
        }
        super.cursorStyleChanged(source: source, newStyle: steadyStyle)
    }
}

extension TerminalController {
    func startProcessIfNeeded() {
        guard let invocation else { return }
        let view: SteadyCursorTerminalView
        if let retained = retainedTerminalView as? SteadyCursorTerminalView {
            view = retained
        } else {
            view = SteadyCursorTerminalView(frame: .zero)
            view.optionAsMetaKey = true
            view.allowMouseReporting = true
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.getTerminal().changeScrollback(scrollbackLines)
            view.font =
                NSFont(name: "NotoMonoForPowerline", size: 16) ??
                NSFont.monospacedSystemFont(
                    ofSize: 16,
                    weight: .regular
                )
            retainTerminalView(view)
        }
        view.restorationController = self
        view.processDelegate = processDelegate
        if view.process.running {
            processStarted(for: connectionToken)
            scheduleRestoredCommandIfNeeded(
                in: view,
                token: connectionToken
            )
            return
        }
        if let buffer = consumeRestoredTerminalBuffer() {
            let replay = SessionRestorationStore.replayBuffer(buffer)
            view.feed(byteArray: Array(replay)[...])
        }

        var environment = invocation.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let environmentList = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        view.startProcess(
            executable: invocation.executableURL.path,
            args: invocation.arguments,
            environment: environmentList,
            execName: invocation.executableURL.lastPathComponent
        )
        processStarted(for: connectionToken)
        scheduleRestoredCommandIfNeeded(
            in: view,
            token: connectionToken
        )
    }
}

extension TerminalTheme {
    var backgroundColor: NSColor {
        palette.background
    }

    fileprivate var palette: TerminalPalette {
        switch self {
        case .night:
            TerminalPalette(
                background: NSColor(hex: 0x090C14),
                foreground: NSColor(hex: 0xDCE3F0),
                cursor: NSColor(hex: 0x65A8FF),
                ansi: [
                    0x1B2230, 0xFF6B72, 0x54D68C, 0xFFD166,
                    0x65A8FF, 0xC792EA, 0x4DD7E5, 0xDCE3F0,
                    0x5C667A, 0xFF8B91, 0x76E6A5, 0xFFE08A,
                    0x8BC0FF, 0xDBA8F2, 0x76E7F0, 0xFFFFFF
                ]
            )
        case .graphite:
            TerminalPalette(
                background: NSColor(hex: 0x171717),
                foreground: NSColor(hex: 0xE5E5E5),
                cursor: NSColor(hex: 0xF5F5F5),
                ansi: [
                    0x262626, 0xE06C75, 0x98C379, 0xE5C07B,
                    0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDCDC,
                    0x5C6370, 0xFF7A85, 0xB4E88D, 0xFFD68A,
                    0x80C7FF, 0xDFA1F2, 0x72D6E0, 0xFFFFFF
                ]
            )
        case .solarizedDark:
            TerminalPalette(
                background: NSColor(hex: 0x002B36),
                foreground: NSColor(hex: 0x93A1A1),
                cursor: NSColor(hex: 0x2AA198),
                ansi: [
                    0x073642, 0xDC322F, 0x859900, 0xB58900,
                    0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                    0x586E75, 0xCB4B16, 0x586E75, 0x657B83,
                    0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
                ]
            )
        case .light:
            TerminalPalette(
                background: NSColor(hex: 0xF7F8FA),
                foreground: NSColor(hex: 0x20242C),
                cursor: NSColor(hex: 0x2869C8),
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

private struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi: [UInt32]
}

@MainActor
private func applyTheme(
    _ theme: TerminalTheme,
    to view: LocalProcessTerminalView
) {
    let palette = theme.palette
    view.nativeBackgroundColor = palette.background
    view.nativeForegroundColor = palette.foreground
    view.caretColor = palette.cursor
    view.caretTextColor = palette.background
    view.selectedTextBackgroundColor = palette.cursor.withAlphaComponent(0.35)
    view.installColors(palette.ansi.map(SwiftTerm.Color.init(hexRGB:)))
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

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
