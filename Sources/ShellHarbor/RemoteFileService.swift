import Foundation

struct RemoteDirectoryListing: Sendable {
    let path: String
    let entries: [FileEntry]
}

struct RemotePathNavigation: Sendable {
    let listing: RemoteDirectoryListing
    let selectedEntryID: FileEntry.ID?
}

enum RemoteFileService {
    static func list(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        path: String
    ) async throws -> [FileEntry] {
        try await resolvedListing(
            profile: profile,
            jumpProfile: jumpProfile,
            path: path
        ).entries
    }

    static func resolvedListing(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        path: String
    ) async throws -> RemoteDirectoryListing {
        let script = listingScript(path: path)
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: script,
            connectionTimeoutSeconds: 12,
            batchMode: true
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(result.exitCode, result.output)
        }
        return try parseResolvedOutput(
            result.output,
            requestedPath: path
        )
    }

    static func listingScript(path: String) -> String {
        let target = remoteShellPath(path)
        return """
        cd -- \(target) && \
        { setopt NULL_GLOB 2>/dev/null || true; } && \
        printf '\\n__SHELLHARBOR_PWD__\\t%s\\n' "$(pwd -P)" && \
        if stat -f '%z %m %B' . >/dev/null 2>&1; then stat_style=bsd; else stat_style=gnu; fi; \
        for f in .[^.]* *; do \
          [ "$f" = "." ] && continue; [ "$f" = ".." ] && continue; \
          [ -e "$f" ] || [ -L "$f" ] || continue; \
          if [ -d "$f" ]; then t=d; else t=f; fi; \
          if [ "$stat_style" = bsd ]; then \
            meta=$(stat -f '%z %m %B' "$f" 2>/dev/null || printf '0 0 0'); \
          else \
            meta=$(stat -c '%s %Y %W' -- "$f" 2>/dev/null || printf '0 0 0'); \
          fi; \
          s=${meta%% *}; meta=${meta#* }; m=${meta%% *}; c=${meta#* }; \
          [ "$t" = d ] && s=0; \
          printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$t" "$s" "$m" "$c" "$f"; \
        done
        """
    }

    static func resolvedNavigation(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        path: String
    ) async throws -> RemotePathNavigation {
        do {
            return RemotePathNavigation(
                listing: try await resolvedListing(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    path: path
                ),
                selectedEntryID: nil
            )
        } catch {
            let directoryError = error
            let fileName = (path as NSString).lastPathComponent
            let parentPath = parent(of: path)
            guard !fileName.isEmpty, parentPath != path else {
                throw directoryError
            }

            let parentListing: RemoteDirectoryListing
            do {
                parentListing = try await resolvedListing(
                    profile: profile,
                    jumpProfile: jumpProfile,
                    path: parentPath
                )
            } catch {
                throw directoryError
            }
            guard let file = parentListing.entries.first(where: {
                $0.name == fileName && !$0.isDirectory
            }) else {
                throw directoryError
            }
            return RemotePathNavigation(
                listing: parentListing,
                selectedEntryID: file.id
            )
        }
    }

    static func createDirectory(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        parentPath: String,
        name: String
    ) async throws {
        let fullPath = join(parentPath, name)
        let command = "mkdir -p -- \(remoteShellPath(fullPath))"
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: command,
            connectionTimeoutSeconds: 12,
            batchMode: true
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(result.exitCode, result.output)
        }
    }

    static func pathSize(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        path: String
    ) async throws -> Int64 {
        let command = pathSizeScript(path: path)
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: command,
            connectionTimeoutSeconds: 12,
            batchMode: true
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(
                result.exitCode,
                result.output
            )
        }
        guard
            let size = result.output
                .split(whereSeparator: \.isNewline)
                .reversed()
                .compactMap({ Int64(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                ) })
                .first
        else {
            throw SSHServiceError.commandFailed(
                0,
                "无法解析远程文件大小：\(path)"
            )
        }
        return size
    }

    static func pathSizeScript(path: String) -> String {
        let target = remoteShellPath(path)
        return """
        if [ -d \(target) ]; then
          {
            if stat -f '%z' \(target) >/dev/null 2>&1; then
              find \(target) -type f -exec stat -f '%z' {} \\; 2>/dev/null
            else
              find \(target) -type f -exec stat -c '%s' -- {} \\; 2>/dev/null
            fi
          } | awk '{ total += $1 } END { printf "%.0f\\n", total }'
        elif [ -f \(target) ]; then
          wc -c < \(target) 2>/dev/null || printf '0\n'
        else
          printf '0\n'
        fi
        """
    }

    static func delete(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        entry: FileEntry
    ) async throws {
        let flag = entry.isDirectory ? "-rf" : "-f"
        let command = "rm \(flag) -- \(remoteShellPath(entry.path))"
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: command,
            connectionTimeoutSeconds: 12,
            batchMode: true
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(result.exitCode, result.output)
        }
    }

    static func rename(
        profile: SessionProfile,
        jumpProfile: SessionProfile? = nil,
        entry: FileEntry,
        newName: String
    ) async throws -> String {
        let destination = join(parent(of: entry.path), newName)
        guard destination != entry.path else { return destination }
        let sourceArgument = remoteShellPath(entry.path)
        let destinationArgument = remoteShellPath(destination)
        let command = """
        if [ -e \(destinationArgument) ] || [ -L \(destinationArgument) ]; then
          printf '目标已存在：%s\\n' \(destinationArgument) >&2
          exit 17
        fi
        mv -- \(sourceArgument) \(destinationArgument)
        """
        let invocation = try SSHCommandBuilder.ssh(
            profile: profile,
            jumpProfile: jumpProfile,
            command: command,
            connectionTimeoutSeconds: 12,
            batchMode: true
        )
        let result = try await CommandRunner.run(invocation)
        guard result.exitCode == 0 else {
            throw SSHServiceError.commandFailed(
                result.exitCode,
                result.output
            )
        }
        return destination
    }

    static func parent(of path: String) -> String {
        if path == "~" || path == "/" { return path }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            let parent = (rest as NSString).deletingLastPathComponent
            return parent.isEmpty ? "~" : "~/" + parent
        }
        let parent = (path as NSString).deletingLastPathComponent
        if path.hasPrefix("/") {
            return parent.isEmpty ? "/" : parent
        }
        return parent.isEmpty ? "." : parent
    }

    static func join(_ parent: String, _ child: String) -> String {
        if parent == "/" { return "/" + child }
        if parent.hasSuffix("/") { return parent + child }
        return parent + "/" + child
    }

    private static func remoteShellPath(_ path: String) -> String {
        if path == "~" { return "$HOME" }
        if path.hasPrefix("~/") {
            return "$HOME/" + SSHCommandBuilder.shellQuote(String(path.dropFirst(2)))
        }
        return SSHCommandBuilder.shellQuote(path)
    }

    static func parseResolvedOutput(
        _ output: String,
        requestedPath: String
    ) throws -> RemoteDirectoryListing {
        let marker = "__SHELLHARBOR_PWD__\t"
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let markerMatch = lines.enumerated().first(where: {
            $0.element.range(of: marker) != nil
        })
        else {
            throw SSHServiceError.commandFailed(
                0,
                "无法解析远程目录完整路径：\(requestedPath)"
            )
        }

        let markerIndex = markerMatch.offset
        let markerLine = markerMatch.element
        guard let markerRange = markerLine.range(of: marker) else {
            throw SSHServiceError.commandFailed(
                0,
                "无法解析远程目录完整路径：\(requestedPath)"
            )
        }
        let resolvedPath = String(markerLine[markerRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPath.isEmpty else {
            throw SSHServiceError.commandFailed(
                0,
                "远程目录返回了空路径：\(requestedPath)"
            )
        }

        let listingOutput = lines
            .dropFirst(markerIndex + 1)
            .joined(separator: "\n")
        return RemoteDirectoryListing(
            path: resolvedPath,
            entries: parse(listingOutput, parentPath: resolvedPath)
        )
    }

    private static func parse(_ output: String, parentPath: String) -> [FileEntry] {
        output.split(separator: "\n").compactMap { rawLine in
            let parts = rawLine.split(
                separator: "\t",
                maxSplits: 4,
                omittingEmptySubsequences: false
            )
            guard parts.count == 4 || parts.count == 5 else { return nil }
            let nameIndex = parts.count == 5 ? 4 : 3
            let name = String(parts[nameIndex])
            guard !name.isEmpty else { return nil }
            let modifiedAt = date(from: parts[2])
            let createdAt = parts.count == 5
                ? date(from: parts[3])
                : nil
            return FileEntry(
                name: name,
                path: join(parentPath, name),
                isDirectory: parts[0] == "d",
                size: integer(from: parts[1]) ?? 0,
                modifiedAt: modifiedAt,
                createdAt: createdAt
            )
        }
    }

    private static func integer(from value: Substring) -> Int64? {
        Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func date(from value: Substring) -> Date? {
        guard
            let timestamp = TimeInterval(
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            ),
            timestamp > 0
        else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}
