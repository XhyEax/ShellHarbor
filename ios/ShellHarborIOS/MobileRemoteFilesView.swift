import SwiftUI
import UniformTypeIdentifiers

struct MobileRemoteFilesView: View {
    let session: MobileSession
    @State private var isImporting = false
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var renamingFile: MobileRemoteFile?
    @State private var renameValue = ""
    @State private var deletingFile: MobileRemoteFile?

    private var browser: MobileSFTPBrowser { session.fileBrowser }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { browser.goToParent() } label: { Image(systemName: "chevron.up") }
                    .disabled(browser.currentPath == "/" || browser.isLoading)
                TextField("远端路径", text: Binding(
                    get: { browser.currentPath },
                    set: { browser.currentPath = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { browser.refresh() }
                Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.isLoading)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(browser.entries) { file in
                Button { browser.open(file) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(file.isDirectory ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).lineLimit(1)
                            HStack {
                                if let size = file.size, !file.isDirectory {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                }
                                if let modifiedAt = file.modifiedAt { Text(modifiedAt, style: .date) }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if file.isDirectory { Image(systemName: "chevron.right").font(.caption) }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("改名", systemImage: "pencil") {
                        renamingFile = file
                        renameValue = file.name
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { deletingFile = file }
                }
            }
            .overlay {
                if browser.isLoading { ProgressView() }
                else if browser.entries.isEmpty { ContentUnavailableView("目录为空", systemImage: "folder") }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { isImporting = true } label: { Label("上传", systemImage: "square.and.arrow.up") }
                Spacer()
                if let transfer = browser.transfers.first {
                    Menu {
                        ForEach(browser.transfers) { item in
                            if item.state == .running {
                                Button("暂停 \(item.name)") { browser.pauseTransfer(item.id) }
                                Button("停止 \(item.name)", role: .destructive) { browser.stopTransfer(item.id) }
                            } else if item.state == .paused {
                                Button("继续 \(item.name)") { browser.resumeTransfer(item.id) }
                                Button("停止 \(item.name)", role: .destructive) { browser.stopTransfer(item.id) }
                            } else {
                                Text("\(item.name)：\(transferState(item))")
                            }
                        }
                        Button("清除已完成") { browser.clearFinishedTransfers() }
                    } label: {
                        Label(transferLabel(transfer), systemImage: transfer.state == .running ? "arrow.up.arrow.down.circle" : (transfer.state == .paused ? "pause.circle" : "checkmark.circle"))
                    }
                }
                Button { isCreatingFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
            }
        }
        .task {
            if browser.entries.isEmpty { browser.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                browser.refresh()
            }
            browser.cancelRefresh()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            do {
                let files = try result.get().map { url in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return (url.lastPathComponent, try Data(contentsOf: url))
                }
                if !files.isEmpty { browser.upload(files: files) }
            } catch {
                browser.errorMessage = error.localizedDescription
            }
        }
        .sheet(item: Binding(get: { browser.preview }, set: { browser.preview = $0 })) { preview in
            MobileRemoteFilePreviewView(preview: preview)
        }
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                let name = newFolderName
                newFolderName = ""
                if !name.isEmpty { browser.createDirectory(named: name) }
            }
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
            Button("取消", role: .cancel) { renamingFile = nil }
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
        .alert("远端文件操作失败", isPresented: Binding(
            get: { browser.errorMessage != nil },
            set: { if !$0 { browser.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { browser.errorMessage = nil }
        } message: {
            Text(browser.errorMessage ?? "未知错误")
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
