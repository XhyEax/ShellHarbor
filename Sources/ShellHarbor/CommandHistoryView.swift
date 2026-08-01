import AppKit
import SwiftUI

struct CommandHistoryView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace

    private var filteredEntries: [CommandHistoryEntry] {
        let query = workspace.commandHistorySearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.commandHistory }
        return workspace.commandHistory.filter {
            $0.command.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("远程命令历史", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if workspace.isLoadingCommandHistory {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await state.refreshCommandHistory(in: workspace) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新")
            }
            .padding(14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "搜索远程命令",
                    text: $workspace.commandHistorySearch
                )
                .textFieldStyle(.plain)
                if !workspace.commandHistorySearch.isEmpty {
                    Button {
                        workspace.commandHistorySearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.2))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider()

            if filteredEntries.isEmpty && !workspace.isLoadingCommandHistory {
                ContentUnavailableView(
                    workspace.commandHistorySearch.isEmpty ? "没有历史记录" : "没有匹配命令",
                    systemImage: "clock",
                    description: Text("支持读取远端 zsh、bash 和 fish 的历史文件。")
                )
            } else {
                List(filteredEntries) { entry in
                    Button {
                        state.insertHistoryCommand(entry, in: workspace)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.command)
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let date = entry.date {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复制命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                entry.command,
                                forType: .string
                            )
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 540, height: 480)
    }
}
