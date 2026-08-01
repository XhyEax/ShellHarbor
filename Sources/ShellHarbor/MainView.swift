import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HSplitView {
            SessionSidebar()
                .frame(
                    minWidth: 220,
                    idealWidth: 250,
                    maxWidth: 320,
                    maxHeight: .infinity
                )
            WorkspaceHost()
                .frame(
                    minWidth: 720,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SessionShortcutMonitor(
                onNewSession: { state.newSession() },
                onCloseSession: { state.closeCurrentSession() },
                onClearTerminal: { state.terminal.clear() }
            )
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $state.showingSessionEditor) {
            if let profile = state.editingSession {
                SessionEditorView(
                    profile: profile,
                    availableJumpRemotes: state.sessions
                ) {
                    state.saveEditedSession($0)
                } onCancel: {
                    state.showingSessionEditor = false
                    state.editingSession = nil
                }
            }
        }
        .sheet(isPresented: $state.showingLocalSettings) {
            LocalSettingsView()
                .environmentObject(state)
        }
        .overlay {
            if let notice = state.notice {
                NoticeOverlay(message: notice) {
                    state.notice = nil
                }
            }
        }
        .preferredColorScheme(state.terminalTheme.preferredColorScheme)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            state.saveSessionRestorationNow()
        }
    }
}

private struct NoticeOverlay: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("ShellHarbor", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }

                ScrollView {
                    Text(message)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
                .frame(maxHeight: 260)
            }
            .padding(18)
            .frame(width: 520)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.7))
            }
            .shadow(radius: 18, y: 8)
        }
        .transition(.opacity)
        .zIndex(100)
    }
}

private struct SessionShortcutMonitor: NSViewRepresentable {
    let onNewSession: @MainActor () -> Void
    let onCloseSession: @MainActor () -> Void
    let onClearTerminal: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onNewSession: onNewSession,
            onCloseSession: onCloseSession,
            onClearTerminal: onClearTerminal
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onNewSession = onNewSession
        context.coordinator.onCloseSession = onCloseSession
        context.coordinator.onClearTerminal = onClearTerminal
    }

    static func dismantleNSView(
        _ view: NSView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        var onNewSession: @MainActor () -> Void
        var onCloseSession: @MainActor () -> Void
        var onClearTerminal: @MainActor () -> Void
        private var eventMonitor: Any?

        init(
            onNewSession: @escaping @MainActor () -> Void,
            onCloseSession: @escaping @MainActor () -> Void,
            onClearTerminal: @escaping @MainActor () -> Void
        ) {
            self.onNewSession = onNewSession
            self.onCloseSession = onCloseSession
            self.onClearTerminal = onClearTerminal
        }

        func install() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown
            ) { [weak self] event in
                guard
                    !event.isARepeat,
                    event.window?.attachedSheet == nil
                else { return event }

                let relevantModifiers = event.modifierFlags.intersection([
                    .command, .shift, .option, .control
                ])
                guard relevantModifiers == .command else { return event }

                switch event.charactersIgnoringModifiers?.lowercased() {
                case "n", "t":
                    self?.onNewSession()
                    return nil
                case "w":
                    self?.onCloseSession()
                    return nil
                case "k":
                    self?.onClearTerminal()
                    return nil
                case "v":
                    guard
                        let paths = TerminalFilePasteDecoder.paths(
                            from: .general
                        ),
                        self?.pasteFilePaths(
                            paths,
                            in: event.window
                        ) == true
                    else {
                        return event
                    }
                    return nil
                default:
                    return event
                }
            }
        }

        private func pasteFilePaths(
            _ paths: [String],
            in window: NSWindow?
        ) -> Bool {
            guard
                !paths.isEmpty,
                let responder = window?.firstResponder
            else {
                return false
            }
            if let terminal = responder as? SteadyCursorTerminalView {
                terminal.insertFilePaths(paths)
                return true
            }

            let plainPaths = paths.joined(separator: "\n")
            if let textView = responder as? NSTextView {
                textView.insertText(
                    plainPaths,
                    replacementRange: textView.selectedRange()
                )
                return true
            }
            if let textInput = responder as? NSTextInputClient {
                textInput.insertText(
                    plainPaths,
                    replacementRange: NSRange(
                        location: NSNotFound,
                        length: 0
                    )
                )
                return true
            }
            return false
        }

        func uninstall() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

private struct WorkspaceHost: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.activeWorkspaces.isEmpty {
                ActiveSessionBar()
                Divider()
            }

            if let workspace = state.selectedWorkspace {
                SessionDetail(workspace: workspace)
            } else {
                EmptyWorkspaceView()
            }
        }
    }
}

private struct ActiveSessionBar: View {
    @EnvironmentObject private var state: AppState
    @State private var dropTargetWorkspaceID: UUID?
    @State private var draggedWorkspaceID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(state.activeWorkspaces) { workspace in
                    ActiveSessionTab(
                        workspace: workspace,
                        isSelected: workspace.id == state.selectedWorkspaceID,
                        onSelect: {
                            state.selectWorkspace(workspace.id)
                        },
                        onClose: {
                            state.closeWorkspace(workspace.id)
                        },
                        onCloseOthers: {
                            state.closeOtherWorkspaces(
                                keeping: workspace.id
                            )
                        },
                        onCloseToRight: {
                            state.closeWorkspacesToRight(
                                of: workspace.id
                            )
                        },
                        canCloseOthers:
                            state.activeWorkspaceIDs.count > 1,
                        canCloseToRight:
                            !state.activeWorkspaceIDs
                                .workspaceIDsToRight(of: workspace.id)
                                .isEmpty
                    )
                    .onDrag {
                        draggedWorkspaceID = workspace.id
                        return NSItemProvider(
                            object: workspace.id.uuidString as NSString
                        )
                    } preview: {
                        Label(
                            workspace.displayName,
                            systemImage: "terminal"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .onDrop(
                        of: [UTType.utf8PlainText],
                        delegate: SessionTabDropDelegate(
                            sourceID: draggedWorkspaceID,
                            targetID: workspace.id,
                            targetMidpoint: tabMidpoint(for: workspace),
                            dropTargetID: $dropTargetWorkspaceID,
                            draggedWorkspaceID: $draggedWorkspaceID,
                            onReorder: state.reorderWorkspace
                        )
                    )
                    .overlay {
                        if dropTargetWorkspaceID == workspace.id {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    Color.accentColor,
                                    lineWidth: 2
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
                if let selected = state.selectedWorkspace {
                    Button {
                        state.newSession(for: selected.remoteID)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("新建当前 Remote 的 Session")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 42)
        .background(.bar)
    }

    private func tabMidpoint(
        for workspace: SessionWorkspace
    ) -> CGFloat {
        let textWidth = (
            workspace.displayName as NSString
        ).size(withAttributes: [
            .font: NSFont.systemFont(
                ofSize: NSFont.smallSystemFontSize
            )
        ]).width
        return (textWidth + 65) / 2
    }
}

private struct SessionTabDropDelegate: DropDelegate {
    let sourceID: UUID?
    let targetID: UUID
    let targetMidpoint: CGFloat
    @Binding var dropTargetID: UUID?
    @Binding var draggedWorkspaceID: UUID?
    let onReorder: (UUID, UUID, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        sourceID != nil && sourceID != targetID
    }

    func dropEntered(info: DropInfo) {
        guard sourceID != targetID else { return }
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID {
            dropTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard sourceID != nil, sourceID != targetID else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceID, sourceID != targetID else { return false }
        onReorder(
            sourceID,
            targetID,
            info.location.x >= targetMidpoint
        )
        dropTargetID = nil
        draggedWorkspaceID = nil
        return true
    }
}

private struct ActiveSessionTab: View {
    @ObservedObject var workspace: SessionWorkspace
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseToRight: () -> Void
    let canCloseOthers: Bool
    let canCloseToRight: Bool
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var lastClickTime: TimeInterval = 0
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isRenaming {
                HStack(spacing: 7) {
                    statusIndicator
                    TextField("Session 名称", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 90, maxWidth: 180)
                        .focused($renameFieldFocused)
                        .onSubmit {
                            commitRename()
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                        .onChange(
                            of: renameFieldFocused
                        ) { _, isFocused in
                            if !isFocused, isRenaming {
                                commitRename()
                            }
                        }
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 7)
            } else {
                Button(action: handleTabClick) {
                    HStack(spacing: 7) {
                        statusIndicator
                        Text(workspace.displayName)
                            .font(
                                .caption.weight(
                                    isSelected ? .semibold : .regular
                                )
                            )
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 38, height: 30)
            .contentShape(Rectangle())
            .help("关闭 Session")
        }
        .padding(.trailing, 3)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : .clear)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("关闭 Session", action: onClose)
            Divider()
            Button("关闭其他 Session", action: onCloseOthers)
                .disabled(!canCloseOthers)
            Button("关闭右侧 Session", action: onCloseToRight)
                .disabled(!canCloseToRight)
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(workspace.terminal.state.color)
            .frame(width: 7, height: 7)
    }

    private func handleTabClick() {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick =
            now - lastClickTime <= NSEvent.doubleClickInterval

        onSelect()
        if isDoubleClick {
            lastClickTime = 0
            beginRename()
        } else {
            lastClickTime = now
        }
    }

    private func beginRename() {
        renameDraft = workspace.sessionLabel
        isRenaming = true
        DispatchQueue.main.async {
            renameFieldFocused = true
        }
    }

    private func commitRename() {
        workspace.rename(to: renameDraft)
        isRenaming = false
        renameFieldFocused = false
    }

    private func cancelRename() {
        isRenaming = false
        renameFieldFocused = false
    }
}

private struct SessionDetail: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBar(
                workspace: workspace,
                mode: $workspace.mode
            )
            Divider()
            WorkspaceContent(
                workspace: workspace,
                mode: workspace.mode
            )
        }
        .onAppear {
            workspace.prepareIfNeeded()
        }
        .onChange(of: workspace.mode) { _, mode in
            state.rememberWorkspaceMode(mode, for: workspace)
        }
        .alert(
            "确认 SSH 主机密钥",
            isPresented: Binding(
                get: { workspace.terminal.hostKeyConfirmation != nil },
                set: { presented in
                    if !presented {
                        workspace.terminal.respondToHostKeyConfirmation(
                            accept: false
                        )
                    }
                }
            )
        ) {
            Button("信任并继续") {
                workspace.terminal.respondToHostKeyConfirmation(accept: true)
            }
            Button("取消连接", role: .cancel) {
                workspace.terminal.respondToHostKeyConfirmation(accept: false)
            }
        } message: {
            Text(workspace.terminal.hostKeyConfirmation?.prompt ?? "")
        }
        .onChange(of: workspace.localSortColumn) {
            state.rememberFileSort(for: workspace)
        }
        .onChange(of: workspace.localSortAscending) {
            state.rememberFileSort(for: workspace)
        }
        .onChange(of: workspace.remoteSortColumn) {
            state.rememberFileSort(for: workspace)
        }
        .onChange(of: workspace.remoteSortAscending) {
            state.rememberFileSort(for: workspace)
        }
    }
}

private struct RemoteGroupRenameRequest: Identifiable {
    let id = UUID()
    let name: String
}

enum RemoteMultiSelection {
    static func range(
        from anchorID: UUID,
        through targetID: UUID,
        in orderedIDs: [UUID]
    ) -> Set<UUID> {
        guard
            let anchorIndex = orderedIDs.firstIndex(of: anchorID),
            let targetIndex = orderedIDs.firstIndex(of: targetID)
        else {
            return [targetID]
        }
        let bounds = min(anchorIndex, targetIndex)...max(
            anchorIndex,
            targetIndex
        )
        return Set(orderedIDs[bounds])
    }
}

private struct SessionSidebar: View {
    @EnvironmentObject private var state: AppState
    @State private var lastRemoteClickID: UUID?
    @State private var lastRemoteClickTime: TimeInterval = 0
    @State private var isEditingRemotes = false
    @State private var selectedRemoteIDs = Set<UUID>()
    @State private var remoteSelectionAnchorID: UUID?
    @State private var showingDeleteConfirmation = false
    @State private var showingNewGroup = false
    @State private var newGroupTargetIDs = Set<UUID>()
    @State private var renamingGroup: RemoteGroupRenameRequest?
    @State private var dropTargetRemoteID: UUID?
    @State private var draggedRemoteID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ShellHarbor")
                        .font(.title3.weight(.semibold))
                    Text("Remote 与 Session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    toggleRemoteEditing()
                } label: {
                    Image(
                        systemName: isEditingRemotes
                            ? "checkmark"
                            : "pencil"
                    )
                }
                .buttonStyle(.borderless)
                .help(isEditingRemotes ? "完成编辑" : "编辑 Remote")
                .disabled(state.sessions.isEmpty)
                Button {
                    state.addSession()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("新建 Remote")
                .disabled(isEditingRemotes)
            }
            .padding(14)

            List(selection: Binding(
                get: { isEditingRemotes ? nil : state.selectedSessionID },
                set: {
                    if !isEditingRemotes {
                        state.selectSession($0)
                    }
                }
            )) {
                Section {
                    LocalSessionRow(
                        shell: state.localShell,
                        activeSessionCount: state.activeSessionCount(
                            for: state.localSessionID
                        )
                    )
                    .tag(state.localSessionID)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleLocalClick()
                    }
                    .contextMenu {
                        if !isEditingRemotes {
                            Button("配置 Local Shell") {
                                state.showingLocalSettings = true
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Local")
                        Spacer()
                        Button {
                            state.showingLocalSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 8)
                        .help("配置 Local Shell")
                        .disabled(isEditingRemotes)
                    }
                }

                ForEach(remoteGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            remoteRow(session)
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text(group.name)
                            Text("\(group.sessions.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            if group.name != RemoteGroupName.ungrouped {
                                Button("重命名分组…") {
                                    renamingGroup =
                                        RemoteGroupRenameRequest(
                                            name: group.name
                                        )
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if isEditingRemotes {
                Divider()
                HStack(spacing: 10) {
                    Button(
                        selectedRemoteIDs.count == state.sessions.count
                            ? "取消全选"
                            : "全选"
                    ) {
                        if selectedRemoteIDs.count == state.sessions.count {
                            selectedRemoteIDs.removeAll()
                        } else {
                            selectedRemoteIDs = Set(state.sessions.map(\.id))
                        }
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("已选 \(selectedRemoteIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Menu {
                        groupAssignmentButtons(
                            for: selectedRemoteIDs
                        )
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("移动到分组")
                    .disabled(selectedRemoteIDs.isEmpty)

                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除选中的 Remote")
                    .disabled(selectedRemoteIDs.isEmpty)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
            }
        }
        .background(.ultraThinMaterial)
        .alert(
            "删除 \(selectedRemoteIDs.count) 个 Remote？",
            isPresented: $showingDeleteConfirmation
        ) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                state.deleteRemotes(selectedRemoteIDs)
                selectedRemoteIDs.removeAll()
                if state.sessions.isEmpty {
                    isEditingRemotes = false
                }
            }
        } message: {
            Text("相关的已打开 Session 也会断开并关闭。")
        }
        .sheet(isPresented: $showingNewGroup) {
            NewRemoteGroupSheet(
                existingGroupNames: namedGroupNames,
                onCreate: { groupName in
                    state.assignRemotes(
                        newGroupTargetIDs,
                        toGroup: groupName
                    )
                    newGroupTargetIDs.removeAll()
                    showingNewGroup = false
                },
                onCancel: {
                    newGroupTargetIDs.removeAll()
                    showingNewGroup = false
                }
            )
        }
        .sheet(item: $renamingGroup) { request in
            RenameRemoteGroupSheet(
                currentName: request.name,
                existingGroupNames: namedGroupNames.filter {
                    $0.caseInsensitiveCompare(request.name) != .orderedSame
                },
                onRename: { newName in
                    state.renameRemoteGroup(request.name, to: newName)
                    renamingGroup = nil
                },
                onCancel: {
                    renamingGroup = nil
                }
            )
        }
    }

    private var remoteGroups: [RemoteGroupSection] {
        RemoteGroupSection.sections(from: state.sessions)
    }

    private var namedGroupNames: [String] {
        remoteGroups
            .map(\.name)
            .filter { $0 != RemoteGroupName.ungrouped }
    }

    private var visibleRemoteIDs: [UUID] {
        remoteGroups.flatMap { $0.sessions.map(\.id) }
    }

    private func toggleRemoteEditing() {
        isEditingRemotes.toggle()
        if isEditingRemotes {
            if
                let currentID = state.selectedSessionID,
                state.sessions.contains(where: { $0.id == currentID })
            {
                selectedRemoteIDs = [currentID]
                remoteSelectionAnchorID = currentID
            } else {
                selectedRemoteIDs.removeAll()
                remoteSelectionAnchorID = nil
            }
        } else {
            selectedRemoteIDs.removeAll()
            remoteSelectionAnchorID = nil
        }
    }

    private func remoteRow(_ session: SessionProfile) -> some View {
        SessionRow(
            session: session,
            activeSessionCount: state.activeSessionCount(
                for: session.id
            ),
            isEditing: isEditingRemotes,
            isBatchSelected: selectedRemoteIDs.contains(session.id),
            latestInspection: state.latestInspectionRecord(
                for: session.id
            ),
            hasInteractiveConnection: state.hasInteractiveConnection(
                for: session.id
            ),
            isInspecting: state.inspectingRemoteIDs.contains(session.id),
            dragProvider: {
                draggedRemoteID = session.id
                return NSItemProvider(
                    object: session.id.uuidString as NSString
                )
            }
        )
        .tag(session.id)
        .contentShape(Rectangle())
        .onTapGesture {
            handleRemoteClick(session.id)
        }
        .onDrag {
            draggedRemoteID = session.id
            return NSItemProvider(
                object: session.id.uuidString as NSString
            )
        } preview: {
            remoteDragPreview(session)
        }
        .onDrop(
            of: [UTType.utf8PlainText],
            delegate: RemoteDropDelegate(
                sourceID: draggedRemoteID,
                targetID: session.id,
                targetMidpoint: 28,
                dropTargetID: $dropTargetRemoteID,
                draggedRemoteID: $draggedRemoteID,
                onReorder: state.reorderRemote
            )
        )
        .overlay {
            if dropTargetRemoteID == session.id {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .help(
            isEditingRemotes
                ? "\(session.resolvedRemoteGroup) · 拖动右侧手柄调整顺序或移动分组"
                : "\(session.resolvedRemoteGroup) · 按住并拖动以调整顺序或移动分组"
        )
        .contextMenu {
            if !isEditingRemotes {
                Button("编辑 Remote") {
                    state.selectedSessionID = session.id
                    state.editSelectedSession()
                }
                Button("复制 Remote") {
                    state.selectedSessionID = session.id
                    state.duplicateSelectedSession()
                }
                Menu("移动到分组") {
                    groupAssignmentButtons(for: [session.id])
                }
                Divider()
                Button("删除 Remote", role: .destructive) {
                    state.selectedSessionID = session.id
                    state.deleteSelectedSession()
                }
            }
        }
    }

    @ViewBuilder
    private func groupAssignmentButtons(
        for remoteIDs: Set<UUID>
    ) -> some View {
        Button {
            state.assignRemotes(remoteIDs, toGroup: nil)
        } label: {
            Label(RemoteGroupName.ungrouped, systemImage: "tray")
        }
        if !namedGroupNames.isEmpty {
            Divider()
            ForEach(namedGroupNames, id: \.self) { groupName in
                Button {
                    state.assignRemotes(
                        remoteIDs,
                        toGroup: groupName
                    )
                } label: {
                    Label(groupName, systemImage: "folder")
                }
            }
        }
        Divider()
        Button {
            newGroupTargetIDs = remoteIDs
            showingNewGroup = true
        } label: {
            Label("新建分组…", systemImage: "folder.badge.plus")
        }
    }

    private func remoteDragPreview(
        _ session: SessionProfile
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: session.resolvedRemoteIcon.symbol)
                .foregroundStyle(Color.accentColor)
            Text(session.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func handleRemoteClick(_ remoteID: UUID) {
        let modifiers = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.shift) {
            let anchor = remoteSelectionAnchorID ?? (
                state.selectedSessionID.flatMap { selectedID in
                    visibleRemoteIDs.contains(selectedID)
                        ? selectedID
                        : nil
                } ?? remoteID
            )
            if !isEditingRemotes {
                isEditingRemotes = true
                selectedRemoteIDs = [anchor]
            }
            let range = RemoteMultiSelection.range(
                from: anchor,
                through: remoteID,
                in: visibleRemoteIDs
            )
            if modifiers.contains(.command) {
                selectedRemoteIDs.formUnion(range)
            } else {
                selectedRemoteIDs = range
            }
            remoteSelectionAnchorID = anchor
            return
        }

        if isEditingRemotes {
            if selectedRemoteIDs.contains(remoteID) {
                selectedRemoteIDs.remove(remoteID)
            } else {
                selectedRemoteIDs.insert(remoteID)
            }
            remoteSelectionAnchorID = remoteID
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick =
            lastRemoteClickID == remoteID &&
            now - lastRemoteClickTime <= NSEvent.doubleClickInterval

        state.selectSession(remoteID)
        remoteSelectionAnchorID = remoteID
        if isDoubleClick {
            lastRemoteClickID = nil
            lastRemoteClickTime = 0
            state.connect(to: remoteID)
        } else {
            lastRemoteClickID = remoteID
            lastRemoteClickTime = now
        }
    }

    private func handleLocalClick() {
        guard !isEditingRemotes else { return }
        let remoteID = state.localSessionID
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick =
            lastRemoteClickID == remoteID &&
            now - lastRemoteClickTime <= NSEvent.doubleClickInterval

        state.selectSession(remoteID)
        if isDoubleClick {
            lastRemoteClickID = nil
            lastRemoteClickTime = 0
            state.connect(to: remoteID)
        } else {
            lastRemoteClickID = remoteID
            lastRemoteClickTime = now
        }
    }
}

private struct LocalSessionRow: View {
    let shell: LocalShell
    let activeSessionCount: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(
                    shell == .system
                        ? "本机默认 · \(shell.shellName)"
                        : shell.shellName
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            if activeSessionCount > 0 {
                Text("\(activeSessionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .help("\(activeSessionCount) 个已打开的 Local Session")
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RemoteDropDelegate: DropDelegate {
    let sourceID: UUID?
    let targetID: UUID
    let targetMidpoint: CGFloat
    @Binding var dropTargetID: UUID?
    @Binding var draggedRemoteID: UUID?
    let onReorder: (UUID, UUID, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        sourceID != nil && sourceID != targetID
    }

    func dropEntered(info: DropInfo) {
        guard sourceID != targetID else { return }
        dropTargetID = targetID
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID {
            dropTargetID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard sourceID != nil, sourceID != targetID else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceID, sourceID != targetID else { return false }
        onReorder(
            sourceID,
            targetID,
            info.location.y >= targetMidpoint
        )
        dropTargetID = nil
        draggedRemoteID = nil
        return true
    }
}

private struct SessionRow: View {
    let session: SessionProfile
    let activeSessionCount: Int
    let isEditing: Bool
    let isBatchSelected: Bool
    let latestInspection: InspectionRecord?
    let hasInteractiveConnection: Bool
    let isInspecting: Bool
    let dragProvider: () -> NSItemProvider

    var body: some View {
        HStack(spacing: 10) {
            if isEditing {
                Image(
                    systemName: isBatchSelected
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .foregroundStyle(
                    isBatchSelected ? Color.accentColor : Color.secondary
                )
            }
            Image(systemName: session.resolvedRemoteIcon.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(session.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if session.jumpRemoteID != nil {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("通过已有 Remote 作为 JumpHost 代理连接")
            } else if session.isProxyEnabled {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help(session.proxySummary ?? "通过 Proxy 连接")
            }
            if isInspecting {
                ProgressView()
                    .controlSize(.mini)
                    .help("正在巡检")
            } else if hasInteractiveConnection {
                Label("在线", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.13), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.green.opacity(0.35), lineWidth: 1)
                    }
            } else if let latestInspection {
                let status = latestInspection.healthStatus
                Label(status.title, systemImage: status.icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.color)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        status.color.opacity(0.13),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(status.color.opacity(0.35), lineWidth: 1)
                    }
                    .help(
                        "最近巡检：\(latestInspection.timestamp.formatted(date: .abbreviated, time: .shortened))"
                    )
            }
            if activeSessionCount > 0 {
                Text("\(activeSessionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .help("\(activeSessionCount) 个已打开的 Session")
                    .accessibilityLabel(
                        "\(activeSessionCount) 个已打开的 Session"
                    )
            }
            if isEditing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
                    .onDrag(dragProvider) {
                        HStack(spacing: 8) {
                            Image(
                                systemName:
                                    session.resolvedRemoteIcon.symbol
                            )
                            Text(session.name)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .help("拖动排序")
                    .accessibilityLabel("拖动 \(session.name) 排序")
            }
        }
        .padding(.vertical, 3)
        .grayscale(isOffline ? 1 : 0)
        .opacity(isOffline ? 0.58 : 1)
    }

    private var isOffline: Bool {
        !hasInteractiveConnection && latestInspection?.healthStatus == .offline
    }
}

private struct ConnectionBar: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @Binding var mode: WorkspaceMode

    var body: some View {
        HStack(spacing: 12) {
            let profile = workspace.profile
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(workspace.terminal.state.color)
                        .frame(width: 7, height: 7)
                    Text(
                        "\(profile.subtitle)" +
                        (
                            profile.isMoshConnection
                                ? (
                                    profile
                                        .resolvedTerminalConnectionMethod ==
                                        .jumpMosh
                                        ? " · 跳板 Mosh"
                                        : " · Mosh"
                                )
                                : ""
                        ) +
                        (workspace.jumpProfile.map {
                            " · 经 \($0.name)"
                        } ?? profile.proxySummary.map {
                            " · \($0)"
                        } ?? "") +
                        (workspace.terminal.state == .connected
                            ? ""
                            : " · \(workspace.terminal.state.label)")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if profile.isLocalConnection {
                Label("本地终端", systemImage: "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 460)
            } else {
                Picker("视图", selection: $mode) {
                    ForEach(WorkspaceMode.allCases) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 460)
            }

            Spacer()

            if profile.isLocalConnection {
                Button {
                    state.showingLocalSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("配置 Local Shell")
            } else if state.isPersistedRemote(workspace.remoteID) {
                Button {
                    state.editRemote(workspace.remoteID)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("编辑 Remote")
            }

            Button {
                state.newSession()
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(!workspace.profile.isConnectable)

            Menu {
                Button("新建 tmux Session") {
                    state.launchMultiplexer(
                        .tmux,
                        for: workspace.remoteID
                    )
                }
                Button("新建 zellij Session") {
                    state.launchMultiplexer(
                        .zellij,
                        for: workspace.remoteID
                    )
                }
            } label: {
                Label("快速启动", systemImage: "bolt.fill")
            }
            .disabled(
                workspace.profile.isLocalConnection ||
                    !workspace.profile.isConnectable
            )

            Button {
                state.reconnect()
            } label: {
                Label("重连", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!workspace.profile.isConnectable)

            Button("断开", role: .destructive) {
                state.disconnect()
            }
            .buttonStyle(.bordered)
            .disabled(
                workspace.terminal.state == .disconnected ||
                workspace.terminal.state.isFailed
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Keeps both panes mounted while changing modes. In particular, the
/// InteractiveTerminalRepresentable retains the same PTY and SSH process when
/// moving between the workspace and terminal tabs.
private struct WorkspaceContent: View {
    @ObservedObject var workspace: SessionWorkspace
    let mode: WorkspaceMode

    var body: some View {
        GeometryReader { geometry in
            let dividerHeight: CGFloat = mode == .workspace ? 1 : 0
            let contentHeight = max(0, geometry.size.height - dividerHeight)
            let terminalHeight: CGFloat = switch mode {
            case .workspace: contentHeight * 0.46
            case .terminal: contentHeight
            case .files, .inspection: 0
            }
            let filesHeight: CGFloat = switch mode {
            case .workspace: max(0, contentHeight - terminalHeight)
            case .files: contentHeight
            case .terminal, .inspection: 0
            }
            let inspectionHeight = mode == .inspection
                ? contentHeight
                : 0

            VStack(spacing: 0) {
                TerminalView(workspace: workspace)
                    .frame(height: terminalHeight)
                    .opacity(
                        mode == .files || mode == .inspection ? 0 : 1
                    )
                    .allowsHitTesting(
                        mode != .files && mode != .inspection
                    )
                    .accessibilityHidden(
                        mode == .files || mode == .inspection
                    )
                    .clipped()

                Divider()
                    .frame(height: dividerHeight)
                    .opacity(mode == .workspace ? 1 : 0)

                FileTransferView(
                    workspace: workspace,
                    isAutoRefreshActive:
                        mode == .files || mode == .workspace
                )
                    .frame(height: filesHeight)
                    .opacity(
                        mode == .terminal || mode == .inspection ? 0 : 1
                    )
                    .allowsHitTesting(
                        mode != .terminal && mode != .inspection
                    )
                    .accessibilityHidden(
                        mode == .terminal || mode == .inspection
                    )
                    .clipped()

                InspectionLogView(workspace: workspace)
                    .frame(height: inspectionHeight)
                    .opacity(mode == .inspection ? 1 : 0)
                    .allowsHitTesting(mode == .inspection)
                    .accessibilityHidden(mode != .inspection)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct EmptyWorkspaceView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingInspectionLogs = false

    var body: some View {
        ContentUnavailableView {
            Label("没有打开的 Session", systemImage: "terminal.fill")
        } description: {
            if state.isLocalSelected || state.sessions.isEmpty {
                Text("启动本机登录 Shell，不经过 SSH。")
            } else if state.selectedSession != nil {
                Text("新建当前 Remote 的 SSH Session；双击左侧 Remote 也可创建。")
            } else {
                Text("请先从左侧选择一个 Remote。")
            }
        } actions: {
            if state.isLocalSelected || state.sessions.isEmpty {
                Button("连接 Local") {
                    state.newSession()
                }
                .buttonStyle(.borderedProminent)
            } else if state.selectedSession != nil {
                HStack {
                    Button("连接 Remote") {
                        state.newSession()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("巡检日志") {
                        showingInspectionLogs = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .sheet(isPresented: $showingInspectionLogs) {
            if let profile = state.selectedSession {
                RemoteInspectionSheet(profile: profile)
                    .environmentObject(state)
            }
        }
    }
}

private struct LocalSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local")
                        .font(.title2.weight(.semibold))
                    Text("本机交互式终端")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Form {
                Picker("Shell", selection: $state.localShell) {
                    ForEach(LocalShell.allCases) { shell in
                        Text(shell.title).tag(shell)
                    }
                }
                .pickerStyle(.radioGroup)

                LabeledContent("启动路径") {
                    Text(state.localShell.resolvedPath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            Text("“跟随本机”会读取当前 macOS 用户的默认登录 Shell。修改后，新建或重连 Local Session 时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("完成") {
                    state.showingLocalSettings = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct RemoteInspectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var workspace: SessionWorkspace

    init(profile: SessionProfile) {
        _workspace = StateObject(
            wrappedValue: SessionWorkspace(profile: profile)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    workspace.profile.name,
                    systemImage:
                        workspace.profile.resolvedRemoteIcon.symbol
                )
                .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            Divider()

            InspectionLogView(workspace: workspace)
        }
        .frame(minWidth: 980, minHeight: 680)
    }
}
