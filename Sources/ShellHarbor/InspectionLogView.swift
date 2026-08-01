import SwiftUI

private enum InspectionLogRange: String, CaseIterable, Identifiable {
    case today
    case sevenDays
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .sevenDays: "近 7 天"
        case .all: "全部"
        }
    }

    func contains(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            guard let start = calendar.date(
                byAdding: .day,
                value: -7,
                to: now
            ) else {
                return true
            }
            return date >= start
        case .all:
            return true
        }
    }
}

struct InspectionLogView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: SessionWorkspace
    @State private var selectedRange: InspectionLogRange = .today
    @State private var selectedRecord: InspectionRecord?

    private var allRecords: [InspectionRecord] {
        state.inspectionRecords(for: workspace.remoteID)
    }

    private var records: [InspectionRecord] {
        allRecords.filter { selectedRange.contains($0.timestamp) }
    }

    private var profile: SessionProfile {
        state.sessions.first(where: { $0.id == workspace.remoteID }) ??
            workspace.profile
    }

    private var isInspecting: Bool {
        state.inspectingRemoteIDs.contains(workspace.remoteID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let latest = allRecords.first {
                latestSummary(latest)
                Divider()
            }

            if !records.isEmpty {
                statisticsSummary
                Divider()
                logHeader
                Divider()
                List(records) { record in
                    InspectionLogRow(record: record)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedRecord = record
                        }
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView {
                    Label(
                        allRecords.isEmpty
                            ? "暂无巡检日志"
                            : "当前时间范围没有日志",
                        systemImage: "waveform.path.ecg"
                    )
                } description: {
                    Text(
                        allRecords.isEmpty
                            ? "点击“立即巡检”获取联通、CPU、内存和磁盘状态。"
                            : "请选择其他时间范围，或执行一次新的巡检。"
                    )
                } actions: {
                    Button("立即巡检") {
                        state.inspectNow(workspace.remoteID)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInspecting)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedRecord) { record in
            InspectionDetailView(record: record)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("巡检日志", systemImage: "waveform.path.ecg")
                .font(.headline)

            Text(
                profile.resolvedInspectionEnabled
                    ? "每 \(profile.resolvedInspectionIntervalMinutes) 分钟"
                    : "自动巡检已关闭"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            Picker("时间范围", selection: $selectedRange) {
                ForEach(InspectionLogRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            if isInspecting {
                ProgressView()
                    .controlSize(.small)
                Text("巡检中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                state.inspectNow(workspace.remoteID)
            } label: {
                Label("立即巡检", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isInspecting)

            Button("清空日志") {
                state.clearInspectionRecords(for: workspace.remoteID)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(allRecords.isEmpty || isInspecting)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.bar)
    }

    private var statisticsSummary: some View {
        let statistics = InspectionStatistics(records: records)
        return HStack(spacing: 20) {
            Label(
                "\(selectedRange.title) · \(statistics.total) 次",
                systemImage: "calendar"
            )
            statisticLabel(
                "正常",
                value: statistics.healthy,
                color: .green
            )
            statisticLabel(
                "警告",
                value: statistics.warning,
                color: .orange
            )
            statisticLabel(
                "离线",
                value: statistics.offline,
                color: .red
            )
            Spacer()
            Text(
                "健康率 \(Int((statistics.healthyRate * 100).rounded()))%"
            )
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statisticLabel(
        _ title: String,
        value: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(value)")
        }
        .font(.caption.monospacedDigit())
    }

    private func latestSummary(_ record: InspectionRecord) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: 5
            ),
            spacing: 10
        ) {
            InspectionMetricCard(
                title: "联通情况",
                value: record.isReachable ? "正常" : "失败",
                detail: record.timestamp.formatted(
                    date: .omitted,
                    time: .shortened
                ),
                icon: record.isReachable
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill",
                color: record.isReachable ? .green : .red
            )
            InspectionMetricCard(
                title: "CPU 占用",
                value: record.cpuLabel,
                detail: "当前使用率",
                icon: "cpu",
                color: usageColor(record.cpuUsagePercent)
            )
            InspectionMetricCard(
                title: "内存占用",
                value: record.memoryLabel,
                detail: record.memorySpaceLabel,
                icon: "memorychip",
                color: usageColor(record.memoryUsagePercent)
            )
            InspectionMetricCard(
                title: "磁盘空间",
                value: record.diskSpaceLabel,
                detail: "可用 / 总量",
                icon: "internaldrive",
                color: .blue
            )
            InspectionMetricCard(
                title: "磁盘占用",
                value: record.diskUsageLabel,
                detail: "根目录 /",
                icon: "chart.pie.fill",
                color: usageColor(record.diskUsagePercent)
            )
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var logHeader: some View {
        HStack(spacing: 12) {
            Text("时间")
                .frame(width: 150, alignment: .leading)
            Text("联通")
                .frame(width: 64, alignment: .leading)
            Text("CPU")
                .frame(width: 74, alignment: .trailing)
            Text("内存")
                .frame(width: 74, alignment: .trailing)
            Text("磁盘空间（可用 / 总量）")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("磁盘占用")
                .frame(width: 84, alignment: .trailing)
            Color.clear
                .frame(width: 12)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func usageColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return .green
    }
}

private struct InspectionMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.secondary.opacity(0.16))
        }
    }
}

private struct InspectionLogRow: View {
    let record: InspectionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(
                    record.timestamp.formatted(
                        date: .numeric,
                        time: .standard
                    )
                )
                .font(.caption.monospacedDigit())
                .frame(width: 150, alignment: .leading)

                let status = record.healthStatus
                Label(
                    status.title,
                    systemImage: status.icon
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(status.color)
                .frame(width: 64, alignment: .leading)

                Text(record.cpuLabel)
                    .frame(width: 74, alignment: .trailing)
                Text(record.memoryLabel)
                    .frame(width: 74, alignment: .trailing)
                Text(record.diskSpaceLabel)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(record.diskUsageLabel)
                    .frame(width: 84, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .font(.caption.monospacedDigit())

            if
                let errorMessage = record.errorMessage,
                !errorMessage.isEmpty
            {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.leading, 162)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct InspectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: InspectionRecord

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                let status = record.healthStatus
                Label("单次巡检详情", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Label(status.title, systemImage: status.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.color)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledContent("执行时间") {
                        Text(
                            record.timestamp.formatted(
                                date: .complete,
                                time: .standard
                            )
                        )
                        .monospacedDigit()
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 10
                    ) {
                        InspectionMetricCard(
                            title: "CPU 占用",
                            value: record.cpuLabel,
                            detail: "警告线 90%",
                            icon: "cpu",
                            color: metricColor(
                                record.cpuUsagePercent
                            )
                        )
                        InspectionMetricCard(
                            title: "内存占用",
                            value: record.memoryLabel,
                            detail: record.memorySpaceLabel,
                            icon: "memorychip",
                            color: metricColor(
                                record.memoryUsagePercent
                            )
                        )
                        InspectionMetricCard(
                            title: "磁盘占用",
                            value: record.diskUsageLabel,
                            detail: record.diskSpaceLabel,
                            icon: "internaldrive",
                            color: metricColor(
                                record.diskUsagePercent
                            )
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("采集时间线")
                            .font(.headline)
                        timelineStep(
                            "SSH 联通",
                            detail: record.isReachable
                                ? "连接成功"
                                : (record.errorMessage ?? "连接失败"),
                            success: record.isReachable
                        )
                        timelineStep(
                            "CPU 指标",
                            detail: record.cpuUsagePercent == nil
                                ? "未采集"
                                : record.cpuLabel,
                            success: record.cpuUsagePercent != nil
                        )
                        timelineStep(
                            "内存指标",
                            detail: record.memoryUsagePercent == nil
                                ? "未采集"
                                : "\(record.memoryLabel) · \(record.memorySpaceLabel)",
                            success: record.memoryUsagePercent != nil
                        )
                        timelineStep(
                            "磁盘指标",
                            detail: record.diskUsagePercent == nil
                                ? "未采集"
                                : "\(record.diskUsageLabel) · \(record.diskSpaceLabel)",
                            success: record.diskUsagePercent != nil
                        )
                    }

                    if
                        let errorMessage = record.errorMessage,
                        !errorMessage.isEmpty
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("错误日志")
                                .font(.headline)
                            Text(errorMessage)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                                .padding(12)
                                .background(
                                    Color.red.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 680, height: 590)
    }

    private func timelineStep(
        _ title: String,
        detail: String,
        success: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: success
                    ? "checkmark.circle.fill"
                    : "xmark.circle.fill"
            )
            .foregroundStyle(success ? .green : .red)
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func metricColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return .green
    }
}
