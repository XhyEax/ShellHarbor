import Foundation
import Observation
import SwiftUI

struct MobileInspectionRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let remoteID: UUID
    let timestamp: Date
    let cpuPercent: Double?
    let memoryPercent: Double?
    let memoryTotal: Int64?
    let memoryAvailable: Int64?
    let diskPercent: Double?
    let diskTotal: Int64?
    let diskAvailable: Int64?
    let error: String?
    // Optional so inspection logs written by older releases remain decodable.
    // A reachable SSH server can still reject authentication or a command;
    // those failures must not make the Remote appear offline.
    let isReachable: Bool?

    var isWarning: Bool {
        [cpuPercent, memoryPercent, diskPercent].compactMap { $0 }.contains { $0 >= 90 }
    }

    var healthStatus: MobileInspectionHealthStatus {
        guard isActuallyReachable else { return .offline }
        return isWarning ? .warning : .healthy
    }

    var isActuallyReachable: Bool {
        if let isReachable { return isReachable }
        guard let error else { return true }
        return !MobileInspectionStore.isConnectivityFailure(error)
    }
}

enum MobileInspectionHealthStatus: String, Sendable {
    case healthy
    case warning
    case offline

    var title: String {
        switch self {
        case .healthy: "正常"
        case .warning: "警告"
        case .offline: "离线"
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .offline: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .offline: .red
        }
    }
}

@MainActor
@Observable
final class MobileInspectionStore {
    private(set) var records: [MobileInspectionRecord]
    private(set) var runningRemoteIDs: Set<UUID> = []
    private let defaultsKey = "mobileInspectionRecords"

    init() {
        records = UserDefaults.standard.data(forKey: defaultsKey)
            .flatMap { try? JSONDecoder().decode([MobileInspectionRecord].self, from: $0) } ?? []
    }

    func records(for remoteID: UUID) -> [MobileInspectionRecord] {
        records.filter { $0.remoteID == remoteID }.sorted { $0.timestamp > $1.timestamp }
    }

    func inspect(_ session: MobileSession) {
        let remoteID = session.remote.id
        guard runningRemoteIDs.insert(remoteID).inserted else { return }
        Task {
            let record: MobileInspectionRecord
            do {
                let output = try await session.controller.executeInspectionCommand(Self.script)
                record = Self.parse(output, remoteID: remoteID) ?? Self.failure(
                    remoteID,
                    "巡检响应格式无效",
                    isReachable: session.controller.state == .connected
                )
            } catch {
                let message = error.localizedDescription
                record = Self.failure(
                    remoteID,
                    message,
                    isReachable: session.controller.state == .connected ||
                        !Self.isConnectivityFailure(message)
                )
            }
            records.append(record)
            var perRemoteCount: [UUID: Int] = [:]
            records = records.sorted { $0.timestamp > $1.timestamp }.filter { record in
                let count = perRemoteCount[record.remoteID, default: 0]
                guard count < 1_000 else { return false }
                perRemoteCount[record.remoteID] = count + 1
                return true
            }
            runningRemoteIDs.remove(remoteID)
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    func inspectDueSessions(
        remotes: [MobileRemoteProfile],
        sessions: [MobileSession],
        now: Date = Date()
    ) {
        for remote in remotes where remote.inspectionEnabled {
            guard
                !runningRemoteIDs.contains(remote.id),
                let session = sessions.first(where: {
                    $0.remote.id == remote.id && $0.controller.state == .connected
                })
            else { continue }

            let latest = records.lazy
                .filter { $0.remoteID == remote.id }
                .map(\.timestamp)
                .max()
            let interval = TimeInterval(max(1, remote.inspectionIntervalMinutes) * 60)
            guard latest.map({ now.timeIntervalSince($0) >= interval }) ?? true else {
                continue
            }
            inspect(session)
        }
    }

    func clear(remoteID: UUID) {
        records.removeAll { $0.remoteID == remoteID }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func failure(
        _ remoteID: UUID,
        _ message: String,
        isReachable: Bool
    ) -> MobileInspectionRecord {
        MobileInspectionRecord(id: UUID(), remoteID: remoteID, timestamp: Date(), cpuPercent: nil,
            memoryPercent: nil, memoryTotal: nil, memoryAvailable: nil, diskPercent: nil,
            diskTotal: nil, diskAvailable: nil, error: message, isReachable: isReachable)
    }

    private static func parse(_ output: String, remoteID: UUID) -> MobileInspectionRecord? {
        guard output.contains("__SHELLHARBOR_INSPECTION__") else { return nil }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
        func integer(_ key: String) -> Int64? {
            guard let value = values[key] else { return nil }
            return Int64(value) ?? Double(value).map { Int64($0.rounded()) }
        }
        return MobileInspectionRecord(id: UUID(), remoteID: remoteID, timestamp: Date(),
            cpuPercent: double("CPU_PERCENT"), memoryPercent: double("MEMORY_PERCENT"),
            memoryTotal: integer("MEMORY_TOTAL"), memoryAvailable: integer("MEMORY_AVAILABLE"),
            diskPercent: double("DISK_PERCENT"), diskTotal: integer("DISK_TOTAL"),
            diskAvailable: integer("DISK_AVAILABLE"), error: nil, isReachable: true)
    }

    nonisolated static func isConnectivityFailure(_ message: String) -> Bool {
        let value = message.lowercased()
        if value.contains("permission denied") ||
            value.contains("too many authentication failures") ||
            value.contains("authentication failed") {
            return false
        }
        return true
    }

    private static let script = #"""
printf '__SHELLHARBOR_INSPECTION__\n'

cpu_percent=
if [ -r /proc/stat ]; then
  set -- $(awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print idle, total; exit }' /proc/stat)
  idle1=$1
  total1=$2
  sleep 1
  set -- $(awk '/^cpu / { idle=$5+$6; total=0; for (i=2; i<=NF; i++) total+=$i; print idle, total; exit }' /proc/stat)
  cpu_percent=$(awk -v i1="$idle1" -v t1="$total1" -v i2="$1" -v t2="$2" 'BEGIN { delta=t2-t1; if (delta>0) printf "%.1f", ((delta-(i2-i1))*100/delta) }')
elif command -v top >/dev/null 2>&1; then
  cpu_percent=$(LC_ALL=C top -l 2 -n 0 -s 1 2>/dev/null | awk '/CPU usage:/ { idle=$7; gsub(/%/, "", idle); value=100-idle } END { if (value >= 0) printf "%.1f", value }')
fi
if [ -z "$cpu_percent" ]; then
  cpu_percent=$(LC_ALL=C ps -A -o %cpu= 2>/dev/null | awk '{ sum += $1 } END { if (sum > 100) sum=100; if (sum >= 0) printf "%.1f", sum }')
fi

memory_total=
memory_available=
memory_percent=
if [ -r /proc/meminfo ]; then
  memory_total=$(awk '/^MemTotal:/ { print $2 * 1024; exit }' /proc/meminfo)
  memory_available=$(awk '/^MemAvailable:/ { print $2 * 1024; exit }' /proc/meminfo)
elif command -v sysctl >/dev/null 2>&1 && command -v vm_stat >/dev/null 2>&1; then
  memory_total=$(sysctl -n hw.memsize 2>/dev/null)
  page_size=$(vm_stat 2>/dev/null | awk '/page size of/ { gsub(/[^0-9]/, "", $8); print $8; exit }')
  available_pages=$(vm_stat 2>/dev/null | awk '/Pages free:|Pages inactive:|Pages speculative:/ { gsub(/\./, "", $3); sum += $3 } END { print sum }')
  if [ -n "$page_size" ] && [ -n "$available_pages" ]; then
    memory_available=$(awk -v p="$page_size" -v n="$available_pages" 'BEGIN { printf "%.0f", p*n }')
  fi
fi
if [ -n "$memory_total" ] && [ -n "$memory_available" ]; then
  memory_percent=$(awk -v t="$memory_total" -v a="$memory_available" 'BEGIN { if (t>0) printf "%.1f", (t-a)*100/t }')
fi

set -- $(LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $2*1024, $4*1024, $5; exit }')
disk_total=$1
disk_available=$2
disk_percent=$3

printf 'CPU_PERCENT=%s\n' "$cpu_percent"
printf 'MEMORY_PERCENT=%s\n' "$memory_percent"
printf 'MEMORY_TOTAL=%s\n' "$memory_total"
printf 'MEMORY_AVAILABLE=%s\n' "$memory_available"
printf 'DISK_TOTAL=%s\n' "$disk_total"
printf 'DISK_AVAILABLE=%s\n' "$disk_available"
printf 'DISK_PERCENT=%s\n' "$disk_percent"
"""#
}

private enum MobileInspectionRange: String, CaseIterable, Identifiable {
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
        switch self {
        case .today:
            Calendar.current.isDate(date, inSameDayAs: now)
        case .sevenDays:
            date >= (Calendar.current.date(byAdding: .day, value: -7, to: now) ?? .distantPast)
        case .all:
            true
        }
    }
}

struct MobileInspectionView: View {
    @Environment(MobileInspectionStore.self) private var store
    @Environment(RemoteStore.self) private var remoteStore
    private let preferredSession: MobileSession?
    private let remoteID: UUID
    @State private var selectedRange = MobileInspectionRange.today
    @State private var selectedRecord: MobileInspectionRecord?

    init(session: MobileSession) {
        preferredSession = session
        remoteID = session.remote.id
    }

    init(remoteID: UUID) {
        preferredSession = nil
        self.remoteID = remoteID
    }

    private var activeSession: MobileSession? {
        if let preferredSession,
           preferredSession.controller.state == .connected {
            return preferredSession
        }
        return remoteStore.sessions.first {
            $0.remote.id == remoteID && $0.controller.state == .connected
        }
    }

    private var allRecords: [MobileInspectionRecord] {
        store.records(for: remoteID)
    }

    private var records: [MobileInspectionRecord] {
        allRecords.filter { selectedRange.contains($0.timestamp) }
    }

    var body: some View {
        List {
            Section {
                Picker("时间范围", selection: $selectedRange) {
                    ForEach(MobileInspectionRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("自动巡检") {
                let remote = remoteStore.remotes.first { $0.id == remoteID }
                if let remote, remote.inspectionEnabled {
                    Label(
                        "每 \(remote.inspectionIntervalMinutes) 分钟",
                        systemImage: "clock.arrow.circlepath"
                    )
                    Text("应用处于前台且此 Remote 有已连接 Session 时自动执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("自动巡检已关闭", systemImage: "pause.circle")
                }
            }
            if let latest = allRecords.first {
                Section("最近一次") {
                    Label(latest.healthStatus.title, systemImage: latest.healthStatus.symbol)
                        .foregroundStyle(latest.healthStatus.color)
                    metric("CPU 占用", latest.cpuPercent)
                    metric("内存占用", latest.memoryPercent)
                    metric("磁盘占用", latest.diskPercent)
                    LabeledContent("内存可用 / 总量", value: bytes(latest.memoryAvailable, latest.memoryTotal))
                    LabeledContent("磁盘可用 / 总量", value: bytes(latest.diskAvailable, latest.diskTotal))
                    if let error = latest.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("时间", value: latest.timestamp.formatted(date: .abbreviated, time: .standard))
                }
            }
            if !records.isEmpty {
                Section("统计") {
                    let healthy = records.count { $0.healthStatus == .healthy }
                    let warning = records.count { $0.healthStatus == .warning }
                    let offline = records.count { $0.healthStatus == .offline }
                    LabeledContent("巡检次数", value: "\(records.count)")
                    LabeledContent("正常 / 警告 / 离线", value: "\(healthy) / \(warning) / \(offline)")
                    LabeledContent(
                        "健康率",
                        value: "\(Int((Double(healthy) / Double(records.count) * 100).rounded()))%"
                    )
                }
                Section("巡检日志") {
                    ForEach(records) { record in
                        Button { selectedRecord = record } label: {
                            HStack {
                                Image(systemName: record.healthStatus.symbol)
                                    .foregroundStyle(record.healthStatus.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.timestamp.formatted(date: .abbreviated, time: .standard))
                                        .foregroundStyle(.primary)
                                    Text(record.error ?? "CPU \(percent(record.cpuPercent)) · 内存 \(percent(record.memoryPercent)) · 磁盘 \(percent(record.diskPercent))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if allRecords.isEmpty {
                ContentUnavailableView {
                    Label("暂无巡检日志", systemImage: "waveform.path.ecg")
                } description: {
                    Text("立即巡检可获取联通、CPU、内存和磁盘状态。")
                } actions: {
                    Button("立即巡检") {
                        if let activeSession { store.inspect(activeSession) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        store.runningRemoteIDs.contains(remoteID) ||
                            activeSession == nil
                    )
                }
            } else if records.isEmpty {
                ContentUnavailableView {
                    Label(
                        "当前时间范围没有日志",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                } description: {
                    Text("请选择其他时间范围，或执行一次新的巡检。")
                }
            }
        }
        .sheet(item: $selectedRecord) { record in
            MobileInspectionDetailView(record: record)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if store.runningRemoteIDs.contains(remoteID) {
                    ProgressView()
                    Text("巡检中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        if let activeSession { store.inspect(activeSession) }
                    } label: {
                        Label("立即巡检", systemImage: "play.fill")
                    }
                    .disabled(activeSession == nil)
                }
                Spacer()
                Button(role: .destructive) { store.clear(remoteID: remoteID) } label: {
                    Label("清除", systemImage: "trash")
                }
                .disabled(allRecords.isEmpty || store.runningRemoteIDs.contains(remoteID))
            }
        }
    }

    private func metric(_ name: String, _ value: Double?) -> some View {
        LabeledContent(name, value: percent(value))
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func bytes(_ available: Int64?, _ total: Int64?) -> String {
        guard let available, let total else { return "—" }
        return "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))"
    }
}

private struct MobileInspectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let record: MobileInspectionRecord

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    Label(record.healthStatus.title, systemImage: record.healthStatus.symbol)
                        .foregroundStyle(record.healthStatus.color)
                    LabeledContent("巡检时间", value: record.timestamp.formatted(date: .complete, time: .standard))
                }
                Section("资源") {
                    LabeledContent("CPU 占用", value: percent(record.cpuPercent))
                        .foregroundStyle(metricColor(record.cpuPercent))
                    LabeledContent("内存占用", value: percent(record.memoryPercent))
                        .foregroundStyle(metricColor(record.memoryPercent))
                    LabeledContent("内存可用 / 总量", value: bytes(record.memoryAvailable, record.memoryTotal))
                    LabeledContent("磁盘占用", value: percent(record.diskPercent))
                        .foregroundStyle(metricColor(record.diskPercent))
                    LabeledContent("磁盘可用 / 总量", value: bytes(record.diskAvailable, record.diskTotal))
                }
                Section("采集时间线") {
                    timelineRow(
                        "SSH 联通",
                        detail: record.isActuallyReachable
                            ? "连接成功" : (record.error ?? "连接失败"),
                        success: record.isActuallyReachable
                    )
                    timelineRow(
                        "CPU 指标",
                        detail: record.cpuPercent.map(percent) ?? "未采集",
                        success: record.cpuPercent != nil
                    )
                    timelineRow(
                        "内存指标",
                        detail: record.memoryPercent.map(percent) ?? "未采集",
                        success: record.memoryPercent != nil
                    )
                    timelineRow(
                        "磁盘指标",
                        detail: record.diskPercent.map(percent) ?? "未采集",
                        success: record.diskPercent != nil
                    )
                }
                if let error = record.error, !error.isEmpty {
                    Section("错误日志") {
                        Text(error)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("巡检详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0) } ?? "—"
    }

    private func bytes(_ available: Int64?, _ total: Int64?) -> String {
        guard let available, let total else { return "—" }
        return "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))"
    }

    private func metricColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return .green
    }

    private func timelineRow(
        _ title: String,
        detail: String,
        success: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
