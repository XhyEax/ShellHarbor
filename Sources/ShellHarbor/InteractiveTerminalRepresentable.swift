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
    let fontFamily: TerminalFontFamily
    let fontSize: Double
    let isActive: Bool

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
            view.scrollerStyle = .legacy
            view.scrollerControlSize = .small
            view.scrollerKnobStyle = .light
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.getTerminal().changeScrollback(
                controller.scrollbackLines
            )
            controller.retainTerminalView(view)
        }
        // SwiftTerm's Big Sur partial-dirty-region optimization can leave
        // stale glyphs behind when zsh redraws an editable line across rows.
        // Prefer correctness for an interactive terminal: the system may
        // coalesce these invalidations, but it must not preserve old cells.
        view.disableFullRedrawOnAnyChanges = false
        view.scrollerStyle = .legacy
        view.scrollerControlSize = .small
        view.scrollerKnobStyle = .light
        (view as? SteadyCursorTerminalView)?.restorationController =
            controller
        (view as? SteadyCursorTerminalView)?.configureScrollerAutoHide()
        // Match the system wcwidth behavior used by tmux/screen. SwiftTerm's
        // wide default can move its cursor two cells while the remote PTY
        // moves one, which makes text appear out of order after Mosh redraws.
        view.getTerminal().options.regionalIndicatorWidth = .narrow
        applyFont(fontFamily, size: fontSize, to: view)
        view.processDelegate = controller.processDelegate
        applyTheme(theme, to: view)
        context.coordinator.terminalView = view
        context.coordinator.synchronize(
            view: view,
            connectionToken: connectionToken,
            invocation: invocation,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            isActive: isActive
        )
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        controller.retainTerminalView(view)
        context.coordinator.synchronize(
            view: view,
            connectionToken: connectionToken,
            invocation: invocation,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            isActive: isActive
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
        private var lastFontFamily: TerminalFontFamily?
        private var lastFontSize: Double?
        private var isActive = false
        private var isWaitingForStableLayout = false

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
            theme: TerminalTheme,
            fontFamily: TerminalFontFamily,
            fontSize: Double,
            isActive: Bool
        ) {
            if self.isActive != isActive {
                self.isActive = isActive
                if isActive {
                    focusIfActive(view)
                } else if view.window?.firstResponder === view {
                    view.window?.makeFirstResponder(nil)
                }
            }
            if lastTheme != theme {
                lastTheme = theme
                applyTheme(theme, to: view)
            }
            if lastFontFamily != fontFamily || lastFontSize != fontSize {
                lastFontFamily = fontFamily
                lastFontSize = fontSize
                applyFont(fontFamily, size: fontSize, to: view)
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
                focusIfActive(view)
            }

            guard
                startedConnectionToken != connectionToken,
                let invocation
            else { return }

            if view.process.running {
                startedConnectionToken = connectionToken
                controller.processStarted(for: connectionToken)
                controller.scheduleRestoredCommandIfNeeded(
                    in: view,
                    token: connectionToken
                )
                return
            }
            // NSViewRepresentable creates the terminal with a zero frame.
            // Starting forkpty at that point gives the child a 0-column (or
            // fallback 80-column) TTY, so a long first prompt is laid out at
            // a different width from the eventual SwiftUI viewport. Wait for
            // the same stable size that we are willing to propagate later.
            guard view.frame.width >= 120, view.frame.height >= 60 else {
                scheduleSynchronizationAfterLayout(
                    view: view,
                    connectionToken: connectionToken,
                    invocation: invocation,
                    theme: theme,
                    fontFamily: fontFamily,
                    fontSize: fontSize,
                    isActive: isActive
                )
                return
            }
            startedConnectionToken = connectionToken
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
            focusIfActive(view)
        }

        private func scheduleSynchronizationAfterLayout(
            view: LocalProcessTerminalView,
            connectionToken: UUID,
            invocation: SSHInvocation,
            theme: TerminalTheme,
            fontFamily: TerminalFontFamily,
            fontSize: Double,
            isActive: Bool
        ) {
            guard !isWaitingForStableLayout else { return }
            isWaitingForStableLayout = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                [weak self, weak view] in
                guard let self, let view else { return }
                self.isWaitingForStableLayout = false
                self.synchronize(
                    view: view,
                    connectionToken: connectionToken,
                    invocation: invocation,
                    theme: theme,
                    fontFamily: fontFamily,
                    fontSize: fontSize,
                    isActive: isActive
                )
            }
        }

        private func focusIfActive(_ view: LocalProcessTerminalView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard
                    let self,
                    self.isActive,
                    let view,
                    self.terminalView === view
                else { return }
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
    private var remoteUsesAlternateScreen = false
    private var interactionSequenceTail = ""
    private var scrollerHideWorkItem: DispatchWorkItem?

    func configureScrollerAutoHide() {
        DispatchQueue.main.async { [weak self] in
            self?.revealScrollerAndScheduleHide()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        revealScrollerAndScheduleHide()
        super.scrollWheel(with: event)
    }

    private func revealScrollerAndScheduleHide() {
        guard let scroller = subviews.compactMap({ $0 as? NSScroller }).first else {
            return
        }
        scrollerHideWorkItem?.cancel()
        scroller.alphaValue = 1
        let item = DispatchWorkItem { [weak scroller] in
            guard let scroller else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scroller.animator().alphaValue = 0
            }
        }
        scrollerHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI can briefly collapse a retained terminal while switching
        // tabs or workspace modes. Propagating that transient size to the PTY
        // makes interactive redraws (notably zsh completion menus) render at
        // only a handful of columns before the real frame is restored.
        let isTransientCollapse = newSize.width < 120 || newSize.height < 60
        // The app window itself has a much larger minimum size. A frame below
        // this threshold is therefore always an intermediate SwiftUI layout,
        // including the first layout pass of a retained background session.
        // Sending it to mosh/tmux changes the remote PTY width and makes later
        // cursor-addressed redraws overlap even after the real size returns.
        guard !isTransientCollapse else { return }
        super.setFrameSize(newSize)
    }

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

        // Reset origin mode and the scrolling margins before homing. tmux and
        // other full-screen programs can leave either active; CSI H would then
        // be relative to the old margin and the preserved editable line could
        // reappear many rows below the top after a local clear.
        var restoration =
            "\u{1B}[?6l\u{1B}[r\u{1B}[3J\u{1B}[2J\u{1B}[H"
        restoration += currentLine + "\r"
        if cursor.x > 0 {
            restoration += "\u{1B}[\(cursor.x)C"
        }
        feed(text: restoration)
        // Clearing the buffer does not itself reset SwiftTerm's viewport
        // offset. Keep the restored editable line visible at the bottom.
        scrollTo(row: Int.max, notifyAccessibility: false)
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
        trackAlternateScreen(in: Array(slice))
        restorationController?.terminalOutputDidChange(Array(slice))
        // Cursor-addressed editors frequently erase one row and repaint a
        // different row in the same PTY read. SwiftTerm's calculated dirty
        // range does not cover every old glyph in that case, producing the
        // scattered characters seen with long zsh prompts. Redraw the visible
        // surface from the authoritative buffer after each ordered read.
        setNeedsDisplay(bounds)
    }

    func resetRemoteInteractionState() {
        remoteUsesAlternateScreen = false
        interactionSequenceTail = ""
        allowMouseReporting = false
        // Leaving an alternate buffer restores DEC modes saved on entry.
        // A newly-created SwiftTerm buffer has no prior alternate-screen
        // entry, so forcing ?1049l can restore its zero-value
        // savedWraparound and silently disable DECAWM. Re-enable the normal
        // xterm default after clearing stale restored interaction modes.
        feed(text: "\u{1B}[?47l\u{1B}[?1047l\u{1B}[?1049l\u{1B}[?7h\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l")
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
        // Restored output is reset before the live process starts, so the
        // terminal's current mouse mode now reflects live remote output. tmux
        // does not consistently emit a separately observable alternate-screen
        // transition, making mouse mode the authoritative wheel-report gate.
        allowMouseReporting = getTerminal().mouseMode != .off
        interactionSequenceTail = String(text.suffix(24))
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
        if
            relevantModifiers == .control,
            (key == "/" || event.keyCode == 44)
        {
            process.send(data: [0x1F][...])
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
            view.scrollerStyle = .legacy
            view.scrollerControlSize = .small
            view.scrollerKnobStyle = .light
            view.configureScrollerAutoHide()
            view.getTerminal().setCursorStyle(.steadyBlock)
            view.getTerminal().changeScrollback(scrollbackLines)
            view.font = TerminalFontFamily.saved.nsFont(
                size: TerminalFontSizeSettings.savedSize
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
        view.resetRemoteInteractionState()

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

@MainActor
private func applyFont(
    _ family: TerminalFontFamily,
    size: Double,
    to view: LocalProcessTerminalView
) {
    let normalizedSize = TerminalFontSizeSettings.normalized(size)
    let desiredFont = family.nsFont(size: CGFloat(normalizedSize))
    // Assigning TerminalView.font is not a cosmetic no-op: SwiftTerm resets
    // its font metrics and recomputes the terminal grid. Session restoration
    // updates can recreate this representable for every PTY read, so applying
    // the same font repeatedly makes zsh redraw an editable line while the
    // emulator is being resized/reflowed. Keep the grid stable unless the
    // user actually changed the font setting.
    guard
        view.font.fontName != desiredFont.fontName
            || abs(view.font.pointSize - desiredFont.pointSize) > 0.01
    else { return }
    view.font = desiredFont
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
