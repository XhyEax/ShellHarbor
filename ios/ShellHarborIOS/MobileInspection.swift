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

    var isWarning: Bool {
        [cpuPercent, memoryPercent, diskPercent].compactMap { $0 }.contains { $0 >= 90 }
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
                record = Self.parse(output, remoteID: remoteID) ?? Self.failure(remoteID, "巡检响应格式无效")
            } catch {
                record = Self.failure(remoteID, error.localizedDescription)
            }
            records.append(record)
            records = Array(records.sorted { $0.timestamp > $1.timestamp }.prefix(500))
            runningRemoteIDs.remove(remoteID)
            if let data = try? JSONEncoder().encode(records) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    func clear(remoteID: UUID) {
        records.removeAll { $0.remoteID == remoteID }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static func failure(_ remoteID: UUID, _ message: String) -> MobileInspectionRecord {
        MobileInspectionRecord(id: UUID(), remoteID: remoteID, timestamp: Date(), cpuPercent: nil,
            memoryPercent: nil, memoryTotal: nil, memoryAvailable: nil, diskPercent: nil,
            diskTotal: nil, diskAvailable: nil, error: message)
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
            diskAvailable: integer("DISK_AVAILABLE"), error: nil)
    }

    private static let script = #"""
printf '__SHELLHARBOR_INSPECTION__\n'
cpu=$(LC_ALL=C ps -A -o %cpu= 2>/dev/null | awk '{s+=$1} END {if(s>100)s=100; printf "%.1f",s}')
mt=; ma=
if [ -r /proc/meminfo ]; then mt=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo); ma=$(awk '/^MemAvailable:/{print $2*1024}' /proc/meminfo); fi
mp=$(awk -v t="$mt" -v a="$ma" 'BEGIN {if(t>0)printf "%.1f",(t-a)*100/t}')
set -- $(LC_ALL=C df -Pk / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $2*1024,$4*1024,$5}')
printf 'CPU_PERCENT=%s\nMEMORY_PERCENT=%s\nMEMORY_TOTAL=%s\nMEMORY_AVAILABLE=%s\nDISK_TOTAL=%s\nDISK_AVAILABLE=%s\nDISK_PERCENT=%s\n' "$cpu" "$mp" "$mt" "$ma" "$1" "$2" "$3"
"""#
}

struct MobileInspectionView: View {
    @Environment(MobileInspectionStore.self) private var store
    let session: MobileSession

    private var records: [MobileInspectionRecord] { store.records(for: session.remote.id) }

    var body: some View {
        List {
            if let latest = records.first {
                Section("最近一次") {
                    if let error = latest.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        metric("CPU", latest.cpuPercent)
                        metric("内存", latest.memoryPercent)
                        metric("磁盘", latest.diskPercent)
                        LabeledContent("内存可用", value: bytes(latest.memoryAvailable, latest.memoryTotal))
                        LabeledContent("磁盘可用", value: bytes(latest.diskAvailable, latest.diskTotal))
                    }
                    LabeledContent("时间", value: latest.timestamp.formatted(date: .abbreviated, time: .standard))
                }
            }
            Section("历史") {
                ForEach(records.dropFirst()) { record in
                    HStack {
                        Image(systemName: record.error != nil ? "xmark.circle.fill" : (record.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                            .foregroundStyle(record.error != nil ? .red : (record.isWarning ? .orange : .green))
                        Text(record.timestamp, style: .date)
                        Text(record.timestamp, style: .time)
                        Spacer()
                        Text(record.error ?? "CPU \(percent(record.cpuPercent))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .overlay { if records.isEmpty { ContentUnavailableView("暂无巡检记录", systemImage: "gauge") } }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { store.inspect(session) } label: { Label("立即巡检", systemImage: "play.fill") }
                    .disabled(store.runningRemoteIDs.contains(session.remote.id) || session.controller.state != .connected)
                Spacer()
                Button(role: .destructive) { store.clear(remoteID: session.remote.id) } label: { Label("清除", systemImage: "trash") }
                    .disabled(records.isEmpty)
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
