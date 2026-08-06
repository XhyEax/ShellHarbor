import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MobileRemoteFilesView: View {
    private enum Location: String, CaseIterable, Identifiable {
        case local = "本地"
        case remote = "远程"
        var id: String { rawValue }
    }

    let session: MobileSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var location: Location
    @State private var isImporting = false
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var renamingFile: MobileRemoteFile?
    @State private var renamingLocalFile: MobileLocalFile?
    @State private var renameValue = ""
    @State private var deletingFile: MobileRemoteFile?
    @State private var deletingLocalFile: MobileLocalFile?
    @State private var localPreview: MobileLocalFile?
    @State private var showingTransfers = false
    @State private var editMode = EditMode.inactive
    @State private var selectedLocalIDs: Set<String> = []
    @State private var selectedRemoteIDs: Set<String> = []
    @State private var confirmingBatchDelete = false

    private var browser: MobileSFTPBrowser { session.fileBrowser }
    private var localBrowser: MobileLocalFileBrowser { session.localFileBrowser }
    private var usesSplitFilePanes: Bool { horizontalSizeClass == .regular }

    init(session: MobileSession) {
        self.session = session
        let saved = UserDefaults.standard.string(
            forKey: Self.locationDefaultsKey(for: session.remote.id)
        )
        _location = State(initialValue: Location(rawValue: saved ?? "") ?? .remote)
    }

    private var baseContent: AnyView {
        AnyView(Group {
            if usesSplitFilePanes {
                HStack(spacing: 0) {
                    splitPane(title: "本地", location: .local) {
                        localContent
                    }
                    Divider()
                    splitPane(title: "远程", location: .remote) {
                        remoteContent
                    }
                }
            } else {
                VStack(spacing: 0) {
                    Picker("文件位置", selection: $location) {
                        ForEach(Location.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    if location == .local {
                        localContent
                    } else {
                        remoteContent
                    }
                }
            }
        }
        .toolbar {
            fileToolbar
        }
        .task(id: usesSplitFilePanes) {
            if browser.pathInput != browser.currentPath { browser.pathInput = browser.currentPath }
            if usesSplitFilePanes {
                if browser.entries.isEmpty { browser.refresh() }
                localBrowser.refresh()
            } else if location == .remote {
                if browser.entries.isEmpty { browser.refresh() }
            } else {
                localBrowser.refresh()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                if usesSplitFilePanes {
                    browser.refresh()
                    localBrowser.refresh()
                } else if location == .remote {
                    browser.refresh()
                } else {
                    localBrowser.refresh()
                }
            }
            browser.cancelRefresh()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                let urls = try result.get()
                if location == .remote { importForRemoteUpload(urls) }
                else { importIntoLocalDirectory(urls) }
            } catch {
                browser.errorMessage = error.localizedDescription
            }
        }
        .environment(\.editMode, $editMode)
        .onChange(of: location) { _, newLocation in
            UserDefaults.standard.set(
                newLocation.rawValue,
                forKey: Self.locationDefaultsKey(for: session.remote.id)
            )
            clearSelection()
            if usesSplitFilePanes {
                if newLocation == .remote { browser.refresh() }
                else { localBrowser.refresh() }
            } else if newLocation == .remote {
                browser.refresh()
            } else {
                browser.cancelRefresh()
                localBrowser.refresh()
            }
        })
    }

    private static func locationDefaultsKey(for remoteID: UUID) -> String {
        "mobileFileLocation.\(remoteID.uuidString)"
    }

    private func splitPane<Content: View>(
        title: String,
        location paneLocation: Location,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(
                    title,
                    systemImage: paneLocation == .local
                        ? "iphone"
                        : "server.rack"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.bar)
            Divider()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { location = paneLocation }
        )
        .overlay {
            Rectangle()
                .stroke(
                    location == paneLocation
                        ? Color.accentColor.opacity(0.55)
                        : .clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        baseContent
        .sheet(item: Binding(get: { browser.preview }, set: { browser.preview = $0 })) { preview in
            MobileRemoteFilePreviewView(preview: preview)
        }
        .sheet(item: $localPreview) { file in
            MobileLocalFilePreviewView(file: file)
        }
        .sheet(isPresented: $showingTransfers) {
            MobileTransferCenterView(browser: browser)
        }
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                if !name.isEmpty {
                    if location == .remote { browser.createDirectory(named: name) }
                    else { localBrowser.createDirectory(named: name) }
                }
            }
            .disabled(MobileFileNameValidator.normalized(newFolderName) == nil)
            Button("取消", role: .cancel) { newFolderName = "" }
        }
        .alert("改名", isPresented: Binding(
            get: { renamingFile != nil },
            set: { if !$0 { renamingFile = nil } }
        )) {
            TextField("名称", text: $renameValue)
            Button("保存") {
                if let file = renamingFile, !renameValue.isEmpty { browser.rename(file, to: renameValue) }
                renamingFile = nil
            }
            .disabled(
                MobileFileNameValidator.normalized(renameValue) == nil ||
                    renameValue.trimmingCharacters(in: .whitespacesAndNewlines) == renamingFile?.name
            )
            Button("取消", role: .cancel) { renamingFile = nil }
        }
        .alert("本地改名", isPresented: Binding(
            get: { renamingLocalFile != nil },
            set: { if !$0 { renamingLocalFile = nil } }
        )) {
            TextField("名称", text: $renameValue)
            Button("保存") {
                if let file = renamingLocalFile { localBrowser.rename(file, to: renameValue) }
                renamingLocalFile = nil
            }
            .disabled(
                MobileFileNameValidator.normalized(renameValue) == nil ||
                    renameValue.trimmingCharacters(in: .whitespacesAndNewlines) == renamingLocalFile?.name
            )
            Button("取消", role: .cancel) { renamingLocalFile = nil }
        }
        .confirmationDialog(
            "永久删除 \(deletingFile?.name ?? "")？",
            isPresented: Binding(
                get: { deletingFile != nil },
                set: { if !$0 { deletingFile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                if let deletingFile { browser.delete(deletingFile) }
                deletingFile = nil
            }
            Button("取消", role: .cancel) { deletingFile = nil }
        }
        .confirmationDialog(
            "删除已选择的 \(selectedCount) 个项目？",
            isPresented: $confirmingBatchDelete,
            titleVisibility: .visible
        ) {
            Button(location == .remote ? "永久删除" : "删除", role: .destructive) {
                deleteSelection()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "删除本地文件 \(deletingLocalFile?.name ?? "")？",
            isPresented: Binding(
                get: { deletingLocalFile != nil },
                set: { if !$0 { deletingLocalFile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let deletingLocalFile { localBrowser.delete(deletingLocalFile) }
                deletingLocalFile = nil
            }
            Button("取消", role: .cancel) { deletingLocalFile = nil }
        }
        .alert("远端文件操作失败", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "未知错误")
        }
        .alert("本地文件操作失败", isPresented: Binding(
            get: { localBrowser.errorMessage != nil },
            set: { if !$0 { localBrowser.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { localBrowser.errorMessage = nil }
        } message: {
            Text(localBrowser.errorMessage ?? "未知错误")
        }
    }

    @ToolbarContentBuilder
    private var fileToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if editMode.isEditing {
                Button("取消") { clearSelection() }
                Spacer()
                if selectedCount > 0 {
                    Button {
                        transferSelection()
                    } label: {
                        Label(
                            location == .remote ? "下载" : "上传",
                            systemImage: location == .remote
                                ? "square.and.arrow.down" : "square.and.arrow.up"
                        )
                    }
                    Button(role: .destructive) {
                        confirmingBatchDelete = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            } else {
                Button { isImporting = true } label: {
                    Label(location == .remote ? "上传" : "导入", systemImage: "square.and.arrow.up")
                }
                Button("选择", systemImage: "checkmark.circle") { editMode = .active }
                Spacer()
                if let transfer = summaryTransfer {
                    Button { showingTransfers = true } label: {
                        Label(transferLabel(transfer), systemImage: transferSymbol(transfer))
                    }
                }
                Button { isCreatingFolder = true } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private var remoteContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.goToParent() } label: { Image(systemName: "chevron.up") }
                    .disabled(browser.currentPath == "/" || browser.isLoading)
                TextField("远端路径", text: Binding(
                    get: { browser.pathInput },
                    set: { browser.pathInput = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { browser.navigateToPathInput() }
                pathCompletionMenu(
                    candidates: remotePathCompletions,
                    apply: { browser.pathInput = $0 }
                )
                sortMenu(local: false)
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(browser.entries, selection: $selectedRemoteIDs) { file in
                remoteRow(file).tag(file.id)
            }
            .scrollPosition(id: Binding(
                get: { browser.focusedPath },
                set: { _ in }
            ))
            .overlay {
                if browser.isLoading { ProgressView() }
                else if browser.entries.isEmpty { ContentUnavailableView("目录为空", systemImage: "folder") }
            }
        }
    }

    @ViewBuilder
    private func remoteRow(_ file: MobileRemoteFile) -> some View {
        if editMode.isEditing {
            remoteRowLabel(file)
        } else {
            Button {
                if file.isDirectory || browser.canPreview(file) {
                    browser.open(file)
                } else {
                    browser.download(file, to: localBrowser)
                }
            } label: { remoteRowLabel(file) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("下载到本地", systemImage: "square.and.arrow.down") {
                        browser.download(file, to: localBrowser)
                    }
                    Button("改名", systemImage: "pencil") {
                        renamingFile = file
                        renameValue = file.name
                    }
                    Button("复制完整路径", systemImage: "document.on.document") {
                        UIPasteboard.general.string = file.path
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { deletingFile = file }
                }
                .draggable(file.path) {
                    remoteRowLabel(file)
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
        }
    }

    private func remoteRowLabel(_ file: MobileRemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                HStack {
                    if let size = file.size, !file.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    }
                    if let modifiedAt = file.modifiedAt {
                        Text("修改 \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let createdAt = file.createdAt {
                    Text("创建 \(createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if file.isDirectory { Image(systemName: "chevron.right").font(.caption) }
        }
        .listRowBackground(
            browser.focusedPath == file.path ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }

    private func transferSymbol(_ transfer: MobileTransfer) -> String {
        switch transfer.state {
        case .running: "arrow.up.arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "xmark.circle.fill"
        }
    }

    private var summaryTransfer: MobileTransfer? {
        browser.transfers.first(where: {
            $0.state == .running || $0.state == .paused
        }) ?? browser.transfers.first
    }

    private var localContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { localBrowser.goToParent() } label: { Image(systemName: "chevron.up") }
                    .disabled(!localBrowser.canGoToParent)
                TextField("本地路径", text: Binding(
                    get: { localBrowser.pathInput },
                    set: { localBrowser.pathInput = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { localBrowser.navigateToPathInput() }
                pathCompletionMenu(
                    candidates: localPathCompletions,
                    apply: { localBrowser.pathInput = $0 }
                )
                sortMenu(local: true)
                Button { localBrowser.refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(localBrowser.entries, selection: $selectedLocalIDs) { file in
                localRow(file).tag(file.id)
            }
            .scrollPosition(id: Binding(
                get: { localBrowser.focusedPath },
                set: { _ in }
            ))
            .overlay {
                if localBrowser.entries.isEmpty {
                    ContentUnavailableView("目录为空", systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private func localRow(_ file: MobileLocalFile) -> some View {
        if editMode.isEditing {
            localRowLabel(file)
        } else {
            Button {
                if let preview = localBrowser.open(file) {
                    localPreview = MobileLocalFile(
                        url: preview,
                        name: file.name,
                        isDirectory: false,
                        size: file.size,
                        modifiedAt: file.modifiedAt
                    )
                }
            } label: {
                localRowLabel(file)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("上传到远程", systemImage: "square.and.arrow.up") {
                    browser.upload(localFiles: [file])
                }
                if !file.isDirectory {
                    ShareLink(item: file.url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Button("改名", systemImage: "pencil") {
                    renamingLocalFile = file
                    renameValue = file.name
                }
                Button("复制完整路径", systemImage: "document.on.document") {
                    UIPasteboard.general.string = file.url.standardizedFileURL.path
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    deletingLocalFile = file
                }
            }
        }
    }

    private func localRowLabel(_ file: MobileLocalFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1)
                HStack {
                    if let size = file.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let modifiedAt = file.modifiedAt {
                        Text("修改 \(modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let createdAt = file.createdAt {
                    Text("创建 \(createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if file.isDirectory { Image(systemName: "chevron.right").font(.caption) }
        }
        .listRowBackground(
            localBrowser.focusedPath == file.url.standardizedFileURL.path
                ? Color.accentColor.opacity(0.18)
                : Color.clear
        )
    }

    private var selectedCount: Int {
        location == .local ? selectedLocalIDs.count : selectedRemoteIDs.count
    }

    private struct PathCompletion: Identifiable {
        let value: String
        let name: String
        let isDirectory: Bool
        var id: String { value }
    }

    private var remotePathCompletions: [PathCompletion] {
        let input = browser.pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (input as NSString).deletingLastPathComponent
        let fragment = (input as NSString).lastPathComponent
        guard completionParent(parent, matches: browser.currentPath) else { return [] }
        return browser.entries.compactMap { file in
            guard fragment.isEmpty || pathComponent(file.name, hasPrefix: fragment),
                  file.name.caseInsensitiveCompare(fragment) != .orderedSame else { return nil }
            return PathCompletion(
                value: file.path + (file.isDirectory ? "/" : ""),
                name: file.name,
                isDirectory: file.isDirectory
            )
        }
    }

    private var localPathCompletions: [PathCompletion] {
        let input = localBrowser.pathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = (input as NSString).deletingLastPathComponent
        let fragment = (input as NSString).lastPathComponent
        guard completionParent(parent, matches: localBrowser.displayPath) else { return [] }
        let base = localBrowser.displayPath == "/" ? "" : localBrowser.displayPath
        return localBrowser.entries.compactMap { file in
            guard fragment.isEmpty || pathComponent(file.name, hasPrefix: fragment),
                  file.name.caseInsensitiveCompare(fragment) != .orderedSame else { return nil }
            return PathCompletion(
                value: "\(base)/\(file.name)" + (file.isDirectory ? "/" : ""),
                name: file.name,
                isDirectory: file.isDirectory
            )
        }
    }

    private func completionParent(_ parent: String, matches currentPath: String) -> Bool {
        let normalizedParent = parent.isEmpty ? currentPath : parent
        let normalizedCurrent = currentPath.count > 1 && currentPath.hasSuffix("/")
            ? String(currentPath.dropLast()) : currentPath
        let candidate = normalizedParent.count > 1 && normalizedParent.hasSuffix("/")
            ? String(normalizedParent.dropLast()) : normalizedParent
        return candidate == normalizedCurrent || candidate == "." && normalizedCurrent == "."
    }

    private func pathComponent(_ value: String, hasPrefix prefix: String) -> Bool {
        value.range(
            of: prefix,
            options: [.anchored, .caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    @ViewBuilder
    private func pathCompletionMenu(
        candidates: [PathCompletion],
        apply: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(candidates) { candidate in
                Button {
                    apply(candidate.value)
                } label: {
                    Label(
                        candidate.name,
                        systemImage: candidate.isDirectory ? "folder" : "doc"
                    )
                }
            }
        } label: {
            Image(systemName: "text.cursor")
        }
        .disabled(candidates.isEmpty)
        .accessibilityLabel("补全路径")
    }

    private func selectedLocalFiles() -> [MobileLocalFile] {
        localBrowser.entries.filter { selectedLocalIDs.contains($0.id) }
    }

    private func selectedRemoteFiles() -> [MobileRemoteFile] {
        browser.entries.filter { selectedRemoteIDs.contains($0.id) }
    }

    private func transferSelection() {
        if location == .local {
            browser.upload(localFiles: selectedLocalFiles())
        } else {
            for file in selectedRemoteFiles() { browser.download(file, to: localBrowser) }
        }
        clearSelection()
    }

    private func deleteSelection() {
        if location == .local {
            localBrowser.delete(selectedLocalFiles())
        } else {
            browser.delete(selectedRemoteFiles())
        }
        clearSelection()
    }

    private func clearSelection() {
        selectedLocalIDs.removeAll()
        selectedRemoteIDs.removeAll()
        editMode = .inactive
    }

    private func importForRemoteUpload(_ urls: [URL]) {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellHarborUpload-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let files = try urls.map { source -> MobileLocalFile in
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey])
                let sourceIsDirectory = sourceValues.isDirectory == true
                let destination = collisionFreeURL(
                    named: source.lastPathComponent,
                    in: stagingRoot,
                    isDirectory: sourceIsDirectory
                )
                try FileManager.default.copyItem(at: source, to: destination)
                let values = try destination.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey
                ])
                let isDirectory = values.isDirectory == true
                return MobileLocalFile(
                    url: destination,
                    name: destination.lastPathComponent,
                    isDirectory: isDirectory,
                    size: isDirectory ? nil : values.fileSize.map(Int64.init),
                    modifiedAt: values.contentModificationDate
                )
            }
            if files.isEmpty {
                try? FileManager.default.removeItem(at: stagingRoot)
            } else {
                browser.upload(localFiles: files, cleanupRoot: stagingRoot)
            }
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            browser.errorMessage = error.localizedDescription
        }
    }

    private func importIntoLocalDirectory(_ urls: [URL]) {
        do {
            for source in urls {
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory == true
                try FileManager.default.copyItem(
                    at: source,
                    to: localBrowser.collisionFreeURL(
                        for: source.lastPathComponent,
                        isDirectory: isDirectory
                    )
                )
            }
            localBrowser.refresh()
        } catch {
            localBrowser.errorMessage = error.localizedDescription
        }
    }

    private func collisionFreeURL(
        named name: String,
        in directory: URL,
        isDirectory: Bool
    ) -> URL {
        let original = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let pathExtension = isDirectory ? "" : original.pathExtension
        let base = isDirectory ? name : original.deletingPathExtension().lastPathComponent
        for index in 1...10_000 {
            let candidateName = pathExtension.isEmpty
                ? "\(base) (\(index))"
                : "\(base) (\(index)).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func sortMenu(local: Bool) -> some View {
        let selected = local ? localBrowser.sortField : browser.sortField
        let ascending = local ? localBrowser.sortAscending : browser.sortAscending
        return Menu {
            ForEach(MobileFileSortField.allCases) { field in
                Button {
                    if local { localBrowser.setSortField(field) }
                    else { browser.setSortField(field) }
                } label: {
                    if selected == field {
                        Label(field.title, systemImage: "checkmark")
                    } else {
                        Text(field.title)
                    }
                }
            }
            Divider()
            Button {
                if local { localBrowser.toggleSortDirection() }
                else { browser.toggleSortDirection() }
            } label: {
                Label(
                    ascending ? "升序" : "降序",
                    systemImage: ascending ? "arrow.up" : "arrow.down"
                )
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
    }

    private func transferLabel(_ transfer: MobileTransfer) -> String {
        guard transfer.total > 0 else { return transfer.name }
        return "\(ByteCountFormatter.string(fromByteCount: transfer.transferred, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))"
    }

    private func transferState(_ transfer: MobileTransfer) -> String {
        let elapsed = Date().timeIntervalSince(transfer.startedAt)
        switch transfer.state {
        case .running: return transferLabel(transfer)
        case .paused: return "已暂停 · \(transferLabel(transfer))"
        case .completed: return "完成 · \(String(format: "%.1f 秒", elapsed))"
        case .failed: return transfer.message ?? "失败"
        case .stopped: return "已停止"
        }
    }
}

private struct MobileTransferCenterView: View {
    @Environment(\.dismiss) private var dismiss
    let browser: MobileSFTPBrowser

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                List {
                    if !browser.transfers.isEmpty {
                        Section {
                            transferSummary(at: timeline.date)
                        }
                    }
                    ForEach(browser.transfers) { transfer in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: transfer.direction == .upload
                                    ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(transfer.direction == .upload ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(transfer.name).lineLimit(1)
                                    Text(statusTitle(transfer))
                                        .font(.caption)
                                        .foregroundStyle(statusColor(transfer))
                                }
                                Spacer()
                                transferActions(transfer)
                            }

                            Text("\(transfer.source)  →  \(transfer.destination)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)

                            ProgressView(value: progress(transfer))

                            HStack {
                                Text(byteProgress(transfer))
                                Spacer()
                                Text("\(speed(transfer, at: timeline.date)) · \(elapsed(transfer, at: timeline.date))")
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)

                            if let message = transfer.message, transfer.state == .failed {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .overlay {
                    if browser.transfers.isEmpty {
                        ContentUnavailableView("没有传输任务", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .navigationTitle("传输")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("清除已完成") { browser.clearCompletedTransfers() }
                        .disabled(!browser.transfers.contains { $0.state == .completed })
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func transferSummary(at date: Date) -> some View {
        let running = browser.transfers.filter { $0.state == .running }
        let paused = browser.transfers.count { $0.state == .paused }
        let completed = browser.transfers.count { $0.state == .completed }
        let measurable = running.filter { $0.total > 0 }
        let total = measurable.reduce(Int64(0)) { $0 + $1.total }
        let transferred = measurable.reduce(Int64(0)) {
            $0 + min($1.transferred, $1.total)
        }
        let fraction = total > 0 ? Double(transferred) / Double(total) : 0
        let aggregateSpeed = running.reduce(0.0) { $0 + $1.bytesPerSecond(at: date) }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                summaryBadge("\(running.count) 进行中", color: .blue)
                summaryBadge("\(paused) 已暂停", color: .orange)
                summaryBadge("\(completed) 已完成", color: .green)
            }
            if !running.isEmpty {
                if total > 0 {
                    ProgressView(value: fraction)
                    HStack {
                        Text(
                            "\(ByteCountFormatter.string(fromByteCount: transferred, countStyle: .file)) / " +
                            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                        )
                        Spacer()
                        Text("\(Int((fraction * 100).rounded()))%")
                        if aggregateSpeed > 0 {
                            Text(
                                "\(ByteCountFormatter.string(fromByteCount: Int64(aggregateSpeed.rounded()), countStyle: .file))/s"
                            )
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在统计并传输…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func summaryBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    @ViewBuilder
    private func transferActions(_ transfer: MobileTransfer) -> some View {
        if transfer.state == .running {
            Menu {
                Button("暂停", systemImage: "pause") { browser.pauseTransfer(transfer.id) }
                Button("停止", systemImage: "stop.fill", role: .destructive) {
                    browser.stopTransfer(transfer.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        } else if transfer.state == .paused {
            Menu {
                Button("继续", systemImage: "play.fill") { browser.resumeTransfer(transfer.id) }
                Button("停止", systemImage: "stop.fill", role: .destructive) {
                    browser.stopTransfer(transfer.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func progress(_ transfer: MobileTransfer) -> Double {
        guard transfer.total > 0 else { return transfer.state == .completed ? 1 : 0 }
        return min(max(Double(transfer.transferred) / Double(transfer.total), 0), 1)
    }

    private func byteProgress(_ transfer: MobileTransfer) -> String {
        let transferred = ByteCountFormatter.string(fromByteCount: transfer.transferred, countStyle: .file)
        guard transfer.total > 0 else { return transferred }
        let total = ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file)
        return "\(transferred) / \(total)"
    }

    private func speed(_ transfer: MobileTransfer, at date: Date) -> String {
        let value = Int64(transfer.bytesPerSecond(at: date).rounded())
        return "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))/s"
    }

    private func elapsed(_ transfer: MobileTransfer, at date: Date) -> String {
        let seconds = Int(transfer.elapsed(at: date).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func statusTitle(_ transfer: MobileTransfer) -> String {
        switch transfer.state {
        case .running: "传输中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .failed: "失败"
        case .stopped: "已停止"
        }
    }

    private func statusColor(_ transfer: MobileTransfer) -> Color {
        switch transfer.state {
        case .running: .blue
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

private struct MobileRemoteFilePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: MobileFilePreview

    var body: some View {
        NavigationStack {
            Group {
                if let text = preview.text {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "无法预览二进制文件",
                        systemImage: "doc",
                        description: Text(ByteCountFormatter.string(fromByteCount: Int64(preview.data.count), countStyle: .file))
                    )
                }
            }
            .navigationTitle(preview.file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(
                        item: preview.data,
                        preview: SharePreview(preview.file.name, image: Image(systemName: "doc"))
                    ) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

private struct MobileLocalFilePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let file: MobileLocalFile

    var body: some View {
        NavigationStack {
            MobileQuickLookView(url: file.url)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: file.url) {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

private struct MobileQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
