import Foundation

enum InspectionService {
    private static let script = """
    printf '__SHELLHARBOR_INSPECTION__\\n'

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
      available_pages=$(vm_stat 2>/dev/null | awk '/Pages free:|Pages inactive:|Pages speculative:/ { gsub(/\\./, "", $3); sum += $3 } END { print sum }')
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

    printf 'CPU_PERCENT=%s\\n' "$cpu_percent"
    printf 'MEMORY_PERCENT=%s\\n' "$memory_percent"
    printf 'MEMORY_TOTAL=%s\\n' "$memory_total"
    printf 'MEMORY_AVAILABLE=%s\\n' "$memory_available"
    printf 'DISK_TOTAL=%s\\n' "$disk_total"
    printf 'DISK_AVAILABLE=%s\\n' "$disk_available"
    printf 'DISK_PERCENT=%s\\n' "$disk_percent"
    """

    static func inspect(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil
    ) async -> InspectionRecord {
        let timestamp = Date()
        do {
            let invocation = try SSHCommandBuilder.ssh(
                profile: profile,
                jumpProfile: jumpProfile,
                command: script,
                connectionTimeoutSeconds: 10,
                batchMode: true
            )
            let result = try await CommandRunner.run(invocation)
            guard result.exitCode == 0 else {
                return failedRecord(
                    profile: profile,
                    timestamp: timestamp,
                    message: cleanedError(result.output)
                )
            }
            guard let record = parse(
                result.output,
                remoteID: profile.id,
                timestamp: timestamp
            ) else {
                return failedRecord(
                    profile: profile,
                    timestamp: timestamp,
                    message: "巡检响应格式无效"
                )
            }
            return record
        } catch {
            return failedRecord(
                profile: profile,
                timestamp: timestamp,
                message: error.localizedDescription
            )
        }
    }

    static func parse(
        _ output: String,
        remoteID: UUID,
        timestamp: Date = Date()
    ) -> InspectionRecord? {
        let lines = output.components(separatedBy: .newlines)
        guard let markerIndex = lines.firstIndex(
            of: "__SHELLHARBOR_INSPECTION__"
        ) else {
            return nil
        }

        var values: [String: String] = [:]
        for line in lines.dropFirst(markerIndex + 1) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(
                line[line.index(after: separator)...]
            )
        }

        return InspectionRecord(
            id: UUID(),
            remoteID: remoteID,
            timestamp: timestamp,
            isReachable: true,
            cpuUsagePercent: double(values["CPU_PERCENT"]),
            memoryUsagePercent: double(values["MEMORY_PERCENT"]),
            memoryTotalBytes: integer(values["MEMORY_TOTAL"]),
            memoryAvailableBytes: integer(values["MEMORY_AVAILABLE"]),
            diskTotalBytes: integer(values["DISK_TOTAL"]),
            diskAvailableBytes: integer(values["DISK_AVAILABLE"]),
            diskUsagePercent: double(values["DISK_PERCENT"]),
            errorMessage: nil
        )
    }

    private static func double(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }

    private static func integer(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else { return nil }
        if let integer = Int64(value) {
            return integer
        }
        return Double(value).map { Int64($0.rounded()) }
    }

    private static func cleanedError(_ output: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "SSH 无法连接" : value
    }

    private static func failedRecord(
        profile: SessionProfile,
        timestamp: Date,
        message: String
    ) -> InspectionRecord {
        InspectionRecord(
            id: UUID(),
            remoteID: profile.id,
            timestamp: timestamp,
            isReachable: false,
            cpuUsagePercent: nil,
            memoryUsagePercent: nil,
            memoryTotalBytes: nil,
            memoryAvailableBytes: nil,
            diskTotalBytes: nil,
            diskAvailableBytes: nil,
            diskUsagePercent: nil,
            errorMessage: message
        )
    }
}
