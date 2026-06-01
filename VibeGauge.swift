import AppKit
import Foundation
import Security

struct CreditData: Codable {
    var services: [CreditService]
}

struct CreditService: Codable {
    var name: String
    var rows: [CreditRow]
    var refreshedAt: Date? = nil
}

struct CreditRow: Codable {
    var label: String
    var percent: Int
    var remaining: String
}

private struct ResetDisplay {
    let remaining: String
    let expired: Bool
}

fileprivate struct ClaudeRowsSnapshot {
    let rows: [CreditRow]
    let modified: Date
}

fileprivate enum VibeGaugePaths {
    static func claudeDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static func claudeStatusFiles(fileManager: FileManager = .default) -> [URL] {
        let claudeDirectory = claudeDirectory(fileManager: fileManager)
        return [
            claudeDirectory.appendingPathComponent("vibegauge-status.json"),
            claudeDirectory.appendingPathComponent("codex-credits-status.json"),
        ]
    }
}

final class CreditStore {
    private let installer = ClaudeStatusLineInstaller.shared
    private let claudeReader = ClaudeRateLimitReader()
    private let codexReader = CodexRateLimitReader()
    static let placeholder = CreditData(services: [
        CreditService(name: "Claude Code", rows: [
            CreditRow(label: "5h", percent: 0, remaining: "no data"),
            CreditRow(label: "7d", percent: 0, remaining: "no data"),
        ]),
        CreditService(name: "Codex", rows: [
            CreditRow(label: "5h", percent: 0, remaining: "no data"),
            CreditRow(label: "7d", percent: 0, remaining: "no data"),
        ]),
    ])

    init() {
        installer.ensureInstalled()
    }

    func load() -> CreditData {
        var data = Self.placeholder

        if let claudeSnapshot = claudeReader.loadSnapshot() {
            data.services[0].rows = claudeSnapshot.rows
            data.services[0].refreshedAt = claudeSnapshot.modified
        }

        if let codexSnapshot = codexReader.loadSnapshot(signature: sourceSignature()) {
            data.services[1].rows = codexSnapshot.rows
            data.services[1].refreshedAt = codexSnapshot.modified
        }

        return data
    }

    func sourceSignature() -> String {
        [
            claudeReader.sourceSignature(),
            newestSignature(in: fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")),
            newestSignature(in: fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")),
        ].joined(separator: "|")
    }

    private var fileManager: FileManager {
        FileManager.default
    }

    private func fileSignature(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return "\(url.path):missing"
        }

        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        return "\(url.path):\(modified):\(size)"
    }

    private func newestSignature(in root: URL) -> String {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return "\(root.path):missing"
        }

        var newest = ""
        var newestModified: TimeInterval = 0

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
                continue
            }

            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if modified > newestModified {
                newestModified = modified
                newest = "\(url.path):\(modified):\(values.fileSize ?? 0)"
            }
        }

        return newest.isEmpty ? "\(root.path):empty" : newest
    }
}

final class ClaudeStatusLineInstaller {
    static let shared = ClaudeStatusLineInstaller()

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var didRun = false

    func ensureInstalled() {
        lock.lock()
        defer { lock.unlock() }

        guard !didRun else {
            return
        }
        didRun = true

        let claudeDirectory = VibeGaugePaths.claudeDirectory(fileManager: fileManager)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let wrapperURL = claudeDirectory.appendingPathComponent("vibegauge-statusline.sh")
        let originalURL = claudeDirectory.appendingPathComponent("vibegauge-original-statusline.txt")
        let legacyOriginalURL = claudeDirectory.appendingPathComponent("codex-credits-original-statusline.txt")

        guard fileManager.fileExists(atPath: claudeDirectory.path) else {
            return
        }

        installWrapper(at: wrapperURL, originalURL: originalURL)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = object
        }

        let currentStatusLine = settings["statusLine"] as? [String: Any]
        let currentCommand = currentStatusLine?["command"] as? String ?? ""
        if currentCommand.contains(wrapperURL.path) {
            return
        }

        if !currentCommand.isEmpty {
            try? currentCommand.write(to: originalURL, atomically: true, encoding: .utf8)
        } else if !fileManager.fileExists(atPath: originalURL.path),
                  let legacyOriginal = try? String(contentsOf: legacyOriginalURL, encoding: .utf8),
                  !legacyOriginal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? legacyOriginal.write(to: originalURL, atomically: true, encoding: .utf8)
        }

        let refreshInterval = currentStatusLine?["refreshInterval"] as? Int ?? 30
        settings["statusLine"] = [
            "type": "command",
            "command": wrapperURL.path,
            "refreshInterval": refreshInterval,
        ]

        guard let output = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }

        try? output.write(to: settingsURL, options: .atomic)
    }

    private func installWrapper(at wrapperURL: URL, originalURL: URL) {
        let script = """
        #!/bin/bash
        set -euo pipefail

        input=$(cat)
        state="${HOME}/.claude/vibegauge-status.json"
        tmp="${state}.tmp"
        original="\(originalURL.path)"

        printf "%s" "$input" > "$tmp"
        mv "$tmp" "$state"

        if [ -s "$original" ]; then
          original_command=$(cat "$original")
          if [ -n "$original_command" ]; then
            printf "%s" "$input" | bash -lc "$original_command" || true
          fi
        fi
        """

        try? script.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)
    }
}

final class ClaudeRateLimitReader {
    private let fileManager = FileManager.default
    private let apiReader = ClaudeUsageAPIReader()
    private let cacheReader = ClaudeUsageCacheReader()
    private let freshStatusMaxAge: TimeInterval = 120
    private var capturedAt: Date = .distantPast

    fileprivate func loadSnapshot() -> ClaudeRowsSnapshot? {
        if let apiSnapshot = apiReader.loadSnapshot() {
            return apiSnapshot
        }

        let statusSnapshot = statusLineSnapshot()
        if let statusSnapshot, Date().timeIntervalSince(statusSnapshot.modified) <= freshStatusMaxAge {
            return statusSnapshot
        }

        let cacheSnapshot = cacheReader.loadSnapshot()
        return cacheSnapshot ?? statusSnapshot
    }

    private func statusLineSnapshot() -> ClaudeRowsSnapshot? {
        var latestSnapshot: ClaudeRowsSnapshot?

        for file in VibeGaugePaths.claudeStatusFiles(fileManager: fileManager) {
            capturedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast

            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let limits = root["rate_limits"] as? [String: Any] else {
                continue
            }

            var rows: [CreditRow] = []

            if let current = firstLimit(in: limits, keys: ["current_session", "currentSession", "session", "five_hour", "fiveHour", "primary"]) {
                rows.append(row(from: current, label: "5h"))
            }

            if let weekly = firstLimit(in: limits, keys: ["weekly", "weekly_limits", "weeklyLimits", "all_models", "allModels", "seven_day", "sevenDay", "secondary"]) {
                rows.append(row(from: weekly, label: "7d"))
            }

            if !rows.isEmpty {
                let snapshot = ClaudeRowsSnapshot(rows: rows, modified: capturedAt)
                if latestSnapshot == nil || snapshot.modified > latestSnapshot!.modified {
                    latestSnapshot = snapshot
                }
            }
        }

        return latestSnapshot
    }

    func sourceSignature() -> String {
        ([apiReader.sourceSignature(), cacheReader.sourceSignature()] + VibeGaugePaths.claudeStatusFiles(fileManager: fileManager).map(fileSignature))
            .joined(separator: "|")
    }

    private func fileSignature(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return "\(url.path):missing"
        }

        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values.fileSize ?? 0
        return "\(url.path):\(modified):\(size)"
    }

    private func firstLimit(in limits: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let limit = limits[key] as? [String: Any] {
                return limit
            }
        }

        return nil
    }

    private func row(from limit: [String: Any], label: String) -> CreditRow {
        let percent = Int((number(in: limit, keys: ["used_percentage", "used_percent", "percent_used", "percentage", "used"]) ?? 0).rounded())
        let reset = resetDisplay(from: limit)

        return CreditRow(
            label: label,
            percent: reset.expired ? 0 : max(0, min(percent, 100)),
            remaining: reset.remaining
        )
    }

    private func number(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double {
                return value
            }

            if let value = object[key] as? Int {
                return Double(value)
            }

            if let value = object[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }

        return nil
    }

    private func resetDisplay(from limit: [String: Any]) -> ResetDisplay {
        if let seconds = number(in: limit, keys: ["reset_in_seconds", "seconds_until_reset", "remaining_seconds"]) {
            let resetAt = capturedAt.addingTimeInterval(seconds)
            return resetCountdown(until: resetAt.timeIntervalSince1970)
        }

        if let timestamp = number(in: limit, keys: ["resets_at", "reset_at", "resetsAt", "resetAt"]) {
            return resetCountdown(until: timestamp)
        }

        for key in ["remaining", "reset_in", "resets_in", "reset_label", "resetLabel"] {
            if let value = limit[key] as? String, !value.isEmpty {
                return ResetDisplay(remaining: normalizeDurationLabel(value), expired: false)
            }
        }

        for key in ["resets_at", "reset_at", "resetsAt", "resetAt"] {
            if let value = limit[key] as? String, !value.isEmpty {
                if let date = ISO8601DateFormatter().date(from: value) {
                    return resetCountdown(until: date.timeIntervalSince1970)
                }

                return ResetDisplay(remaining: value, expired: false)
            }
        }

        return ResetDisplay(remaining: "no reset", expired: false)
    }

    private func resetCountdown(until timestamp: TimeInterval) -> ResetDisplay {
        let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))
        if seconds == 0 {
            return ResetDisplay(remaining: "now", expired: true)
        }

        return ResetDisplay(remaining: countdown(seconds: seconds), expired: false)
    }

    private func countdown(seconds: Int) -> String {
        if seconds == 0 {
            return "now"
        }

        return formatDuration(seconds: seconds)
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(hours)h \(minutes)m"
    }

    private func normalizeDurationLabel(_ label: String) -> String {
        if let seconds = secondsUntilWeekdayTime(label) {
            return formatDuration(seconds: seconds)
        }

        let compactPattern = #"^(\d+)h(\d{1,2})m$"#

        if let match = label.range(of: compactPattern, options: .regularExpression) {
            return label[match].replacingOccurrences(
                of: compactPattern,
                with: "$1h $2m",
                options: .regularExpression
            )
        }

        return label
    }

    private func secondsUntilWeekdayTime(_ label: String) -> Int? {
        let pattern = #"\b(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\b\s+(\d{1,2}):(\d{2})\s*(AM|PM)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        guard let match = regex.firstMatch(in: label, range: range),
              match.numberOfRanges == 5,
              let weekdayRange = Range(match.range(at: 1), in: label),
              let hourRange = Range(match.range(at: 2), in: label),
              let minuteRange = Range(match.range(at: 3), in: label),
              let periodRange = Range(match.range(at: 4), in: label),
              let hourValue = Int(label[hourRange]),
              let minuteValue = Int(label[minuteRange]) else {
            return nil
        }

        let weekdays = [
            "sun": 1,
            "mon": 2,
            "tue": 3,
            "wed": 4,
            "thu": 5,
            "fri": 6,
            "sat": 7,
        ]
        let weekdayKey = String(label[weekdayRange]).lowercased()
        guard let targetWeekday = weekdays[weekdayKey] else {
            return nil
        }

        let period = String(label[periodRange]).uppercased()
        var hour = hourValue % 12
        if period == "PM" {
            hour += 12
        }

        let now = Date()
        let calendar = Calendar.current
        let currentWeekday = calendar.component(.weekday, from: now)
        var daysAhead = (targetWeekday - currentWeekday + 7) % 7
        var baseDate = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour
        components.minute = minuteValue
        components.second = 0

        if let candidate = calendar.date(from: components), candidate <= now {
            daysAhead += 7
            baseDate = calendar.date(byAdding: .day, value: daysAhead, to: now) ?? now
            components = calendar.dateComponents([.year, .month, .day], from: baseDate)
            components.hour = hour
            components.minute = minuteValue
            components.second = 0
        }

        guard let target = calendar.date(from: components) else {
            return nil
        }

        return max(0, Int(target.timeIntervalSince(now)))
    }
}

final class ClaudeUsageAPIReader {
    private let service = "Claude Code-credentials"
    private let account = NSUserName()
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    fileprivate func loadSnapshot() -> ClaudeRowsSnapshot? {
        guard let accessToken = accessToken(),
              let payload = fetchUsage(accessToken: accessToken),
              let rows = rows(from: payload) else {
            return nil
        }

        return ClaudeRowsSnapshot(rows: rows, modified: Date())
    }

    func sourceSignature() -> String {
        "claude-usage-api:\(Date().timeIntervalSince1970.rounded(.down))"
    }

    private func accessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }

        return token
    }

    private func fetchUsage(accessToken: String) -> [String: Any]? {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("claude-code/2.1.150", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }

            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            result = object
        }.resume()

        _ = semaphore.wait(timeout: .now() + 9)
        return result
    }

    private func rows(from payload: [String: Any]) -> [CreditRow]? {
        var rows: [CreditRow] = []

        if let fiveHour = payload["five_hour"] as? [String: Any] {
            rows.append(row(from: fiveHour, label: "5h"))
        }

        if let sevenDay = payload["seven_day"] as? [String: Any] {
            rows.append(row(from: sevenDay, label: "7d"))
        }

        return rows.isEmpty ? nil : rows
    }

    private func row(from limit: [String: Any], label: String) -> CreditRow {
        let rawUtilization = number(limit["utilization"]) ?? 0
        let percentValue = rawUtilization <= 1 ? rawUtilization * 100 : rawUtilization
        let reset = resetDisplay(from: limit["resets_at"])

        return CreditRow(
            label: label,
            percent: reset.expired ? 0 : max(0, min(Int(percentValue.rounded()), 100)),
            remaining: reset.remaining
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private func resetDisplay(from value: Any?) -> ResetDisplay {
        let date: Date?
        if let timestamp = number(value) {
            date = Date(timeIntervalSince1970: timestamp)
        } else if let text = value as? String {
            date = parseISODate(text)
        } else {
            date = nil
        }

        guard let date else {
            return ResetDisplay(remaining: "no reset", expired: false)
        }

        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds == 0 {
            return ResetDisplay(remaining: "now", expired: true)
        }

        return ResetDisplay(remaining: formatDuration(seconds: seconds), expired: false)
    }

    private func parseISODate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let date = formatter.date(from: text) {
            return date
        }

        return ISO8601DateFormatter().date(from: text)
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(hours)h \(minutes)m"
    }
}

final class ClaudeUsageCacheReader {
    private let fileManager = FileManager.default
    private let maxCacheFileSize = 8 * 1024 * 1024
    private let zstdMagic = Data([0x28, 0xb5, 0x2f, 0xfd])

    fileprivate func loadSnapshot() -> ClaudeRowsSnapshot? {
        for file in usageCacheFiles() {
            guard let data = try? Data(contentsOf: file),
                  data.count <= maxCacheFileSize,
                  let payload = decodeCachedUsagePayload(from: data),
                  let rows = rows(from: payload) else {
                continue
            }

            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return ClaudeRowsSnapshot(rows: rows, modified: modified)
        }

        return nil
    }

    func sourceSignature() -> String {
        guard let file = usageCacheFiles().first,
              let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return "claude-usage-cache:missing"
        }

        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(file.path):\(modified):\(values.fileSize ?? 0)"
    }

    private func usageCacheFiles() -> [URL] {
        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/Cache/Cache_Data")
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modified: Date)] = []

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxCacheFileSize else {
                continue
            }

            files.append((url, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modified > $1.modified }
            .prefix(200)
            .map(\.url)
    }

    private func newestUsageCacheFile() -> URL? {
        for file in usageCacheFiles() {
            guard let data = try? Data(contentsOf: file),
                  data.count <= maxCacheFileSize,
                  let payload = decodeCachedUsagePayload(from: data),
                  rows(from: payload) != nil else {
                continue
            }

            return file
        }

        return nil
    }

    private func decodeCachedUsagePayload(from data: Data) -> [String: Any]? {
        let httpMarker = Data("HTTP/1.1".utf8)
        var searchStart = data.startIndex

        while let magicRange = data.range(of: zstdMagic, options: [], in: searchStart..<data.endIndex) {
            let bodyEnd = data.range(of: httpMarker, options: [], in: magicRange.upperBound..<data.endIndex)?.lowerBound ?? data.endIndex
            let compressed = data.subdata(in: magicRange.lowerBound..<bodyEnd)

            if let jsonData = zstdDecode(compressed),
               let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               rows(from: object) != nil {
                return object
            }

            searchStart = magicRange.upperBound
        }

        return nil
    }

    private func zstdDecode(_ data: Data) -> Data? {
        guard let zstd = zstdExecutable() else {
            return nil
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("vibegauge-zstd-\(UUID().uuidString).json")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dc", "-"]

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = Pipe()

        do {
            try process.run()
            input.fileHandleForWriting.write(data)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }

            let decoded = (try? Data(contentsOf: outputURL)) ?? Data()
            return decoded.isEmpty ? nil : decoded
        } catch {
            return nil
        }
    }

    private func zstdExecutable() -> URL? {
        for path in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"] {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    private func rows(from payload: [String: Any]) -> [CreditRow]? {
        var rows: [CreditRow] = []

        if let fiveHour = payload["five_hour"] as? [String: Any] {
            rows.append(row(from: fiveHour, label: "5h"))
        }

        if let sevenDay = payload["seven_day"] as? [String: Any] {
            rows.append(row(from: sevenDay, label: "7d"))
        }

        return rows.isEmpty ? nil : rows
    }

    private func row(from limit: [String: Any], label: String) -> CreditRow {
        let percent = Int((number(limit["utilization"]) ?? 0).rounded())
        let reset = resetDisplay(from: limit["resets_at"])

        return CreditRow(
            label: label,
            percent: reset.expired ? 0 : max(0, min(percent, 100)),
            remaining: reset.remaining
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }

    private func resetDisplay(from value: Any?) -> ResetDisplay {
        guard let text = value as? String, let date = parseISODate(text) else {
            return ResetDisplay(remaining: "no reset", expired: false)
        }

        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds == 0 {
            return ResetDisplay(remaining: "now", expired: true)
        }

        return ResetDisplay(remaining: formatDuration(seconds: seconds), expired: false)
    }

    private func parseISODate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }

        return ISO8601DateFormatter().date(from: text)
    }

    private func formatDuration(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(hours)h \(minutes)m"
    }
}

private struct CodexLogEvent: Decodable {
    let timestamp: String?
    let rate_limits: CodexRateLimits?
    let payload: CodexPayload?
}

private struct CodexSessionMetaEvent: Decodable {
    let payload: CodexSessionMetaPayload?
}

private struct CodexSessionMetaPayload: Decodable {
    let cwd: String?
}

private struct CodexPayload: Decodable {
    let rate_limits: CodexRateLimits?
}

private struct CodexRateLimits: Decodable {
    let primary: CodexLimit?
    let secondary: CodexLimit?
}

private struct CodexLimit: Decodable {
    let used_percent: Double?
    let window_minutes: Int?
    let resets_at: TimeInterval?
}

private struct CodexRateLimitSnapshot {
    let limits: CodexRateLimits
    let timestamp: Date
    let sourceCwd: String?
}

fileprivate struct CodexRowsSnapshot {
    let rows: [CreditRow]
    let modified: Date
}

final class CodexRateLimitReader {
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let dateFormatter = ISO8601DateFormatter()
    private var cachedSignature: String?
    private var cachedSnapshot: CodexRateLimitSnapshot?

    fileprivate func loadSnapshot(signature: String) -> CodexRowsSnapshot? {
        let snapshot: CodexRateLimitSnapshot?

        if cachedSignature == signature {
            snapshot = cachedSnapshot
        } else {
            snapshot = latestRateLimits()
            cachedSnapshot = snapshot
            cachedSignature = signature
        }

        guard let snapshot else {
            return nil
        }

        var rows: [CreditRow] = []

        if let primary = snapshot.limits.primary {
            rows.append(row(from: primary, fallbackLabel: "5h"))
        }

        if let secondary = snapshot.limits.secondary {
            rows.append(row(from: secondary, fallbackLabel: "7d"))
        }

        return rows.isEmpty ? nil : CodexRowsSnapshot(rows: rows, modified: snapshot.timestamp)
    }

    private func latestRateLimits() -> CodexRateLimitSnapshot? {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions"),
        ]

        var latestSnapshot: CodexRateLimitSnapshot?

        for file in recentJSONLFiles(roots: roots) {
            guard let snapshot = latestRateLimits(in: file) else {
                continue
            }

            if latestSnapshot == nil || snapshot.timestamp > latestSnapshot!.timestamp {
                latestSnapshot = snapshot
            }
        }

        return latestSnapshot
    }

    private func recentJSONLFiles(roots: [URL]) -> [URL] {
        var files: [(url: URL, modified: Date)] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                files.append((url, modified))
            }
        }

        return files
            .sorted { $0.modified > $1.modified }
            .prefix(40)
            .map(\.url)
    }

    private func latestRateLimits(in file: URL) -> CodexRateLimitSnapshot? {
        guard let data = tailData(from: file, maxBytes: 4 * 1024 * 1024) else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        let sourceCwd = sessionCwd(from: file)

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let eventData = String(line).data(using: .utf8),
               let event = try? decoder.decode(CodexLogEvent.self, from: eventData),
               let limits = event.rate_limits ?? event.payload?.rate_limits,
               let timestamp = parseTimestamp(event.timestamp) {
                return CodexRateLimitSnapshot(limits: limits, timestamp: timestamp, sourceCwd: sourceCwd)
            }
        }

        return nil
    }

    private func sessionCwd(from file: URL) -> String? {
        guard let data = headData(from: file, maxBytes: 64 * 1024) else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.contains("\"session_meta\"") {
            guard let eventData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(CodexSessionMetaEvent.self, from: eventData),
                  let cwd = event.payload?.cwd else {
                continue
            }

            return URL(fileURLWithPath: cwd).standardizedFileURL.path
        }

        return nil
    }

    private func parseTimestamp(_ text: String?) -> Date? {
        guard let text else {
            return nil
        }

        if let date = fractionalDateFormatter.date(from: text) {
            return date
        }

        return dateFormatter.date(from: text)
    }

    private func tailData(from file: URL, maxBytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private func headData(from file: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        return try? handle.read(upToCount: maxBytes)
    }

    private func row(from limit: CodexLimit, fallbackLabel: String) -> CreditRow {
        let window = limit.window_minutes ?? 0
        let label: String

        switch window {
        case 300:
            label = "5h"
        case 10_080:
            label = "7d"
        default:
            label = fallbackLabel
        }

        let percent = Int((limit.used_percent ?? 0).rounded())
        let reset = resetDisplay(until: limit.resets_at)

        return CreditRow(
            label: label,
            percent: reset.expired ? 0 : max(0, min(percent, 100)),
            remaining: reset.remaining
        )
    }

    private func resetDisplay(until timestamp: TimeInterval?) -> ResetDisplay {
        guard let timestamp else {
            return ResetDisplay(remaining: "no reset", expired: false)
        }

        let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))

        if seconds == 0 {
            return ResetDisplay(remaining: "now", expired: true)
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return ResetDisplay(remaining: "\(days)d \(hours)h", expired: false)
        }

        return ResetDisplay(remaining: "\(hours)h \(minutes)m", expired: false)
    }
}

private enum WidgetStyle: String, CaseIterable {
    case native
    case mono
    case terminal

    var title: String {
        switch self {
        case .native: return "Native"
        case .mono: return "Mono"
        case .terminal: return "Terminal"
        }
    }

    var size: NSSize {
        NSSize(width: 332, height: 166)
    }
}

private enum WidgetAppearance: String, CaseIterable {
    case light
    case dark

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private struct WidgetTokens {
    let text: NSColor
    let muted: NSColor
    let faint: NSColor
    let track: NSColor
    let hair: NSColor
    let claude: NSColor
    let codex: NSColor
    let warn: NSColor
    let nativeBackground: NSColor
    let nativeBorder: NSColor
    let monoBackground: NSColor
    let monoBorder: NSColor
    let playBackground: NSColor
    let playBorder: NSColor
    let controlBackground: NSColor
    let controlBorder: NSColor
    let controlOn: NSColor
    let termBackgroundTop: NSColor
    let termBackgroundBottom: NSColor
    let termBorder: NSColor
    let termText: NSColor
    let termDim: NSColor
    let termFaint: NSColor
    let termTrack: NSColor
    let termDot: NSColor
    let termFill: NSColor
    let termWarn: NSColor
    let termHair: NSColor

    static func make(_ appearance: WidgetAppearance) -> WidgetTokens {
        switch appearance {
        case .light:
            return WidgetTokens(
                text: .hex(0x1b1d24),
                muted: .hex(0x1b1d24, alpha: 0.52),
                faint: .hex(0x1b1d24, alpha: 0.34),
                track: .hex(0x14161e, alpha: 0.10),
                hair: .hex(0x14161e, alpha: 0.10),
                claude: .hex(0xb86d36),
                codex: .hex(0x4fa88d),
                warn: .hex(0xb85630),
                nativeBackground: .white.withAlphaComponent(0.58),
                nativeBorder: .white.withAlphaComponent(0.85),
                monoBackground: .hex(0xfcfbf9, alpha: 0.86),
                monoBorder: .hex(0x14161e, alpha: 0.10),
                playBackground: .white,
                playBorder: .hex(0x14161e, alpha: 0.07),
                controlBackground: .hex(0x14161e, alpha: 0.05),
                controlBorder: .hex(0x14161e, alpha: 0.10),
                controlOn: .hex(0x14161e, alpha: 0.14),
                termBackgroundTop: .hex(0xe8e9d8),
                termBackgroundBottom: .hex(0xdde0cb),
                termBorder: .hex(0x9aa888),
                termText: .hex(0x3b4230),
                termDim: .hex(0x6f7860),
                termFaint: .hex(0x97a085),
                termTrack: .hex(0xd2d6bf),
                termDot: .hex(0xb9c0a3),
                termFill: .hex(0x5b6347),
                termWarn: .hex(0x9a4a2f),
                termHair: .hex(0xc2c8ad)
            )
        case .dark:
            return WidgetTokens(
                text: .hex(0xf3f4f8),
                muted: .hex(0xf3f4f8, alpha: 0.58),
                faint: .hex(0xf3f4f8, alpha: 0.38),
                track: .white.withAlphaComponent(0.13),
                hair: .white.withAlphaComponent(0.10),
                claude: .hex(0xc57a40),
                codex: .hex(0x5eb79d),
                warn: .hex(0xd07a4a),
                nativeBackground: .hex(0x262834, alpha: 0.52),
                nativeBorder: .white.withAlphaComponent(0.14),
                monoBackground: .hex(0x121216, alpha: 0.80),
                monoBorder: .white.withAlphaComponent(0.10),
                playBackground: .hex(0x23252f),
                playBorder: .white.withAlphaComponent(0.08),
                controlBackground: .white.withAlphaComponent(0.07),
                controlBorder: .white.withAlphaComponent(0.14),
                controlOn: .white.withAlphaComponent(0.20),
                termBackgroundTop: .hex(0x1c1f17),
                termBackgroundBottom: .hex(0x15180f),
                termBorder: .hex(0x4a5340),
                termText: .hex(0xc3cda6),
                termDim: .hex(0x8b9670),
                termFaint: .hex(0x69734f),
                termTrack: .hex(0x242a1b),
                termDot: .hex(0x39402a),
                termFill: .hex(0x9aac72),
                termWarn: .hex(0xd07a4a),
                termHair: .hex(0x333a26)
            )
        }
    }
}

private extension NSColor {
    static func hex(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha
        )
    }
}

final class WidgetView: NSView {
    private static let alwaysOnTopKey = "alwaysOnTop"
    private static let styleKey = "cw-style"
    private static let appearanceKey = "cw-theme"
    private let store = CreditStore()
    private let refreshQueue = DispatchQueue(label: "local.vibegauge.refresh")
    private var creditData: CreditData
    private var timer: Timer?
    private var sourceCheckCounter = 0
    private var sourceSignature: String
    private var refreshInFlight = false
    private var alwaysOnTop: Bool
    private var widgetStyle: WidgetStyle
    private var widgetAppearance: WidgetAppearance
    private var screenRect: NSRect = .zero
    private var tooltipTexts: [NSView.ToolTipTag: String] = [:]
    private var trackingArea: NSTrackingArea?
    private var hoverHint: String?
    private var hoverHintRect: NSRect = .zero
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm a"
        return formatter
    }()
    private let layoutInsetX: CGFloat = 14
    private let layoutInsetY: CGFloat = 13
    private let serviceStartOffset: CGFloat = 36
    private let serviceNameToFirstRow: CGFloat = 17
    private let rowStep: CGFloat = 18
    private let serviceGap: CGFloat = 10
    private let labelColumnWidth: CGFloat = 22
    private let percentColumnWidth: CGFloat = 34
    private let resetColumnWidth: CGFloat = 50
    private let columnGap: CGFloat = 10

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        self.creditData = CreditStore.placeholder
        self.sourceSignature = ""
        self.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? false
        self.widgetStyle = Self.storedStyle()
        self.widgetAppearance = Self.storedAppearance()
        super.init(frame: frameRect)
        wantsLayer = true
        let refreshTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.automaticRefresh()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
        updateTooltips()
        DispatchQueue.main.async { [weak self] in
            self?.refreshNow(checkSignature: true)
        }
    }

    required init?(coder: NSCoder) {
        self.creditData = CreditStore.placeholder
        self.sourceSignature = ""
        self.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? false
        self.widgetStyle = Self.storedStyle()
        self.widgetAppearance = Self.storedAppearance()
        super.init(coder: coder)
        updateTooltips()
        DispatchQueue.main.async { [weak self] in
            self?.refreshNow(checkSignature: true)
        }
    }

    deinit {
        timer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    func reload() {
        refreshNow(checkSignature: true)
    }

    static var initialSize: NSSize {
        storedStyle().size
    }

    private static func storedStyle() -> WidgetStyle {
        let raw = UserDefaults.standard.string(forKey: styleKey) ?? WidgetStyle.native.rawValue
        return WidgetStyle(rawValue: raw) ?? .native
    }

    private static func storedAppearance() -> WidgetAppearance {
        let raw = UserDefaults.standard.string(forKey: appearanceKey) ?? WidgetAppearance.dark.rawValue
        return WidgetAppearance(rawValue: raw) ?? .dark
    }

    private func automaticRefresh() {
        sourceCheckCounter += 1
        refreshNow(checkSignature: sourceCheckCounter >= 4)
    }

    private func refreshNow(checkSignature: Bool) {
        guard !refreshInFlight else {
            return
        }

        refreshInFlight = true
        let shouldCheckSignature = checkSignature || sourceSignature.isEmpty
        if shouldCheckSignature {
            sourceCheckCounter = 0
        }
        let currentSignature = sourceSignature

        refreshQueue.async { [weak self] in
            guard let self else {
                return
            }

            let nextData = self.store.load()
            let nextSignature = shouldCheckSignature ? self.store.sourceSignature() : currentSignature

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.creditData = nextData
                self.sourceSignature = nextSignature
                self.refreshInFlight = false
                self.needsDisplay = true
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let topItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        topItem.state = alwaysOnTop ? .on : .off
        menu.addItem(topItem)
        menu.addItem(styleMenuItem())
        menu.addItem(appearanceMenuItem())
        menu.addItem(withTitle: "Refresh", action: #selector(reloadFromMenu), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func styleMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, style) in WidgetStyle.allCases.enumerated() {
            let child = NSMenuItem(title: style.title, action: #selector(selectStyleFromMenu(_:)), keyEquivalent: "")
            child.target = self
            child.tag = index
            child.state = widgetStyle == style ? .on : .off
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func appearanceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, appearance) in WidgetAppearance.allCases.enumerated() {
            let child = NSMenuItem(title: appearance.title, action: #selector(selectAppearanceFromMenu(_:)), keyEquivalent: "")
            child.target = self
            child.tag = index
            child.state = widgetAppearance == appearance ? .on : .off
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if closeButtonRect.contains(point) {
            NSApplication.shared.terminate(nil)
            return
        }

        if styleButtonRect.contains(point) {
            cycleStyle()
            return
        }

        if appearanceButtonRect.contains(point) {
            toggleAppearance()
            return
        }

        if topButtonRect.contains(point) {
            toggleAlwaysOnTop()
            return
        }

        if refreshButtonRect.contains(point) {
            reload()
            return
        }

        if dragHandleRect.contains(point) || event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            window?.performDrag(with: event)
            return
        }

        window?.performDrag(with: event)
    }

    @objc private func reloadFromMenu() {
        reload()
    }

    private func cycleStyle() {
        let styles = WidgetStyle.allCases
        let index = styles.firstIndex(of: widgetStyle) ?? 0
        widgetStyle = styles[(index + 1) % styles.count]
        UserDefaults.standard.set(widgetStyle.rawValue, forKey: Self.styleKey)
        resizeWindowForCurrentStyle()
        updateTooltips()
        needsDisplay = true
    }

    @objc private func selectStyleFromMenu(_ sender: NSMenuItem) {
        guard WidgetStyle.allCases.indices.contains(sender.tag) else {
            return
        }

        widgetStyle = WidgetStyle.allCases[sender.tag]
        UserDefaults.standard.set(widgetStyle.rawValue, forKey: Self.styleKey)
        resizeWindowForCurrentStyle()
        updateTooltips()
        needsDisplay = true
    }

    private func toggleAppearance() {
        widgetAppearance = widgetAppearance == .dark ? .light : .dark
        UserDefaults.standard.set(widgetAppearance.rawValue, forKey: Self.appearanceKey)
        updateTooltips()
        needsDisplay = true
    }

    @objc private func selectAppearanceFromMenu(_ sender: NSMenuItem) {
        guard WidgetAppearance.allCases.indices.contains(sender.tag) else {
            return
        }

        widgetAppearance = WidgetAppearance.allCases[sender.tag]
        UserDefaults.standard.set(widgetAppearance.rawValue, forKey: Self.appearanceKey)
        updateTooltips()
        needsDisplay = true
    }

    private func resizeWindowForCurrentStyle() {
        guard let window else {
            setFrameSize(widgetStyle.size)
            return
        }

        let oldFrame = window.frame
        var frame = oldFrame
        frame.size = widgetStyle.size
        frame.origin.y = oldFrame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
        setFrameSize(widgetStyle.size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        updateTooltips()
    }

    private func updateTooltips() {
        removeAllToolTips()
        tooltipTexts.removeAll()
        registerTooltip(styleButtonRect, "Switch skin: \(nextStyleTitle())")
        registerTooltip(appearanceButtonRect, "Toggle \(widgetAppearance == .dark ? "light" : "dark") mode")
        registerTooltip(topButtonRect, alwaysOnTop ? "Turn always on top off" : "Keep widget always on top")
        registerTooltip(refreshButtonRect, "Refresh credits now")
        registerTooltip(closeButtonRect, "Close widget")
        registerTooltip(dragHandleRect, "Drag widget")
    }

    private func registerTooltip(_ rect: NSRect, _ text: String) {
        let tag = addToolTip(rect, owner: self, userData: nil)
        tooltipTexts[tag] = text
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipTexts[tag] ?? ""
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next = hoverTarget(at: point)
        if hoverHint != next.text || hoverHintRect != next.rect {
            hoverHint = next.text
            hoverHintRect = next.rect
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverHint != nil {
            hoverHint = nil
            hoverHintRect = .zero
            needsDisplay = true
        }
    }

    private func hoverTarget(at point: NSPoint) -> (text: String?, rect: NSRect) {
        if styleButtonRect.contains(point) {
            return ("Switch skin", styleButtonRect)
        }
        if appearanceButtonRect.contains(point) {
            return (widgetAppearance == .dark ? "Light mode" : "Dark mode", appearanceButtonRect)
        }
        if topButtonRect.contains(point) {
            return (alwaysOnTop ? "Unpin window" : "Keep on top", topButtonRect)
        }
        if refreshButtonRect.contains(point) {
            return ("Refresh credits", refreshButtonRect)
        }
        if closeButtonRect.contains(point) {
            return ("Close widget", closeButtonRect)
        }
        return (nil, .zero)
    }

    private func nextStyleTitle() -> String {
        let styles = WidgetStyle.allCases
        let index = styles.firstIndex(of: widgetStyle) ?? 0
        return styles[(index + 1) % styles.count].title
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey)
        if let window {
            Self.applyWindowBehavior(to: window, alwaysOnTop: alwaysOnTop)
        }
        updateTooltips()
        needsDisplay = true
    }

    static func applyWindowBehavior(to window: NSWindow, alwaysOnTop: Bool) {
        window.level = alwaysOnTop ? .floating : .normal
        window.collectionBehavior = alwaysOnTop
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.fullScreenAuxiliary]
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            NSApplication.shared.terminate(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let tokens = WidgetTokens.make(widgetAppearance)
        switch widgetStyle {
        case .native:
            drawNativeWidget(in: bounds, tokens: tokens)
        case .mono:
            drawMonoWidget(in: bounds, tokens: tokens)
        case .terminal:
            drawTerminalWidget(in: bounds, tokens: tokens)
        }
        drawHoverHint(tokens: tokens)
    }

    private var closeButtonRect: NSRect {
        let screen = activeScreenRect
        let size = controlSize
        return NSRect(x: screen.maxX - size, y: screen.maxY - size, width: size, height: size)
    }

    private var refreshButtonRect: NSRect {
        let screen = activeScreenRect
        let size = controlSize
        return NSRect(x: screen.maxX - size * 2 - controlGap, y: screen.maxY - size, width: size, height: size)
    }

    private var topButtonRect: NSRect {
        let screen = activeScreenRect
        let size = controlSize
        return NSRect(x: screen.maxX - size * 3 - controlGap * 2, y: screen.maxY - size, width: size, height: size)
    }

    private var appearanceButtonRect: NSRect {
        let screen = activeScreenRect
        let size = controlSize
        return NSRect(x: screen.maxX - size * 4 - controlGap * 3, y: screen.maxY - size, width: size, height: size)
    }

    private var styleButtonRect: NSRect {
        let screen = activeScreenRect
        let size = controlSize
        return NSRect(x: screen.maxX - size * 5 - controlGap * 4, y: screen.maxY - size, width: size, height: size)
    }

    private var dragHandleRect: NSRect {
        let screen = activeScreenRect
        return NSRect(x: screen.midX - 14, y: screen.maxY - 16, width: 28, height: 10)
    }

    private var activeScreenRect: NSRect {
        if screenRect == .zero {
            return bounds.insetBy(dx: 14, dy: 14)
        }

        return screenRect
    }

    private var controlSize: CGFloat {
        17
    }

    private var controlGap: CGFloat {
        4
    }

    private func drawNativeWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: layoutInsetX, dy: layoutInsetY)
        drawRounded(rect, radius: 16, fill: tokens.nativeBackground, stroke: tokens.nativeBorder)
        drawHeader(in: screenRect, tokens: tokens, titleSize: 13.2, timePrefix: "")

        var y = screenRect.maxY - serviceStartOffset
        for (index, service) in creditData.services.enumerated() {
            if index > 0 {
                y -= serviceGap
            }

            let accent = accent(for: service, tokens: tokens)
            drawSwatch(at: NSPoint(x: screenRect.minX, y: y + 3), color: accent, size: 7)
            drawServiceHeader(service, at: NSPoint(x: screenRect.minX + 12, y: y), tokens: tokens, nameSize: 11.5, nameColor: tokens.text, metaColor: tokens.faint, mono: false)
            y -= serviceNameToFirstRow

            for row in service.rows {
                drawLinearRow(row, y: y, rect: screenRect, tokens: tokens, accent: accent, height: 5, radius: 3.5, showPercentSymbol: true)
                y -= rowStep
            }
        }
    }

    private func drawMonoWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: layoutInsetX, dy: layoutInsetY)
        drawRounded(rect, radius: 9, fill: tokens.monoBackground, stroke: tokens.monoBorder)
        drawHeader(in: screenRect, tokens: tokens, titleSize: 11.2, timePrefix: "", title: "plan_usage", mono: true)

        var y = screenRect.maxY - serviceStartOffset
        for (index, service) in creditData.services.enumerated() {
            if index > 0 {
                y -= serviceGap
            }

            let accent = accent(for: service, tokens: tokens)
            drawServiceHeader(service, at: NSPoint(x: screenRect.minX, y: y), tokens: tokens, nameSize: 10.8, nameColor: accent, metaColor: tokens.muted, mono: true)
            y -= serviceNameToFirstRow
            for row in service.rows {
                drawMonoRow(row, y: y, rect: screenRect, tokens: tokens, accent: accent)
                y -= rowStep
            }
        }
    }

    private func drawTerminalWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: layoutInsetX, dy: layoutInsetY)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGradient(colors: [tokens.termBackgroundTop, tokens.termBackgroundBottom])?.draw(in: path, angle: -35)
        tokens.termBorder.setStroke()
        path.stroke()
        drawHeader(in: screenRect, tokens: tokens, titleSize: 11.5, timePrefix: "", terminal: true)

        var y = screenRect.maxY - serviceStartOffset
        for (index, service) in creditData.services.enumerated() {
            if index > 0 {
                y -= serviceGap
            }

            drawServiceHeader(service, at: NSPoint(x: screenRect.minX, y: y), tokens: tokens, nameSize: 10.6, nameColor: tokens.termDim, metaColor: tokens.termFaint, mono: true)
            y -= serviceNameToFirstRow
            for row in service.rows {
                drawTerminalRow(row, y: y, rect: screenRect, tokens: tokens)
                y -= rowStep
            }
        }
    }

    private func drawServiceHeader(_ service: CreditService, at point: NSPoint, tokens: WidgetTokens, nameSize: CGFloat, nameColor: NSColor, metaColor: NSColor, mono: Bool) {
        let name = displayName(for: service)
        let nameAttrs = attrs(size: nameSize, weight: .bold, color: nameColor, mono: mono)
        drawText(name, at: point, attrs: nameAttrs)

        guard let refreshedAt = service.refreshedAt else {
            return
        }

        let meta = "refreshed \(relativeAge(from: refreshedAt))"
        let nameWidth = name.size(withAttributes: nameAttrs).width
        let metaAttrs = attrs(size: max(8.6, nameSize - 1.6), weight: .regular, color: metaColor, mono: mono)
        drawText(meta, at: NSPoint(x: point.x + nameWidth + 8, y: point.y + 0.3), attrs: metaAttrs)
    }

    private func drawHeader(in rect: NSRect, tokens: WidgetTokens, titleSize: CGFloat, timePrefix: String, title: String = "Plan Usage", mono: Bool = false, terminal: Bool = false) {
        let text = terminal ? tokens.termText : tokens.text
        let muted = terminal ? tokens.termDim : tokens.faint
        let headerY = rect.maxY - 14
        drawText(title, at: NSPoint(x: rect.minX, y: headerY), attrs: attrs(size: titleSize, weight: .heavy, color: text, mono: mono || terminal))
        let time = timePrefix + shortTimeString()
        let timeAttrs = attrs(size: terminal ? 10.2 : 10.5, weight: .semibold, color: muted, mono: mono || terminal)
        let timeSize = time.size(withAttributes: timeAttrs)
        drawText(time, at: NSPoint(x: styleButtonRect.minX - timeSize.width - 7, y: headerY), attrs: timeAttrs)
        drawWindowButtons(tokens: tokens, terminal: terminal, mono: mono)
    }

    private func drawWindowButtons(tokens: WidgetTokens, terminal: Bool = false, mono: Bool = false) {
        let color = terminal ? tokens.termDim : tokens.muted
        let onColor = terminal ? tokens.termText : tokens.text
        drawButton(rect: styleButtonRect, symbol: "tshirt", fallback: "S", tokens: tokens, color: onColor, terminal: terminal, square: mono)
        drawButton(rect: appearanceButtonRect, symbol: widgetAppearance == .dark ? "moon.fill" : "sun.max.fill", fallback: widgetAppearance == .dark ? "D" : "L", tokens: tokens, color: onColor, active: true, terminal: terminal, square: mono)
        drawButton(rect: topButtonRect, symbol: alwaysOnTop ? "pin.fill" : "pin", fallback: "^", tokens: tokens, color: alwaysOnTop ? onColor : color, active: alwaysOnTop, terminal: terminal, square: mono)
        drawButton(rect: refreshButtonRect, symbol: "arrow.clockwise", fallback: "R", tokens: tokens, color: color, terminal: terminal, square: mono)
        drawButton(rect: closeButtonRect, symbol: "xmark", fallback: "X", tokens: tokens, color: color, terminal: terminal, square: mono)
    }

    private func drawHoverHint(tokens: WidgetTokens) {
        guard let hoverHint else {
            return
        }

        let textColor = widgetStyle == .terminal ? tokens.termText : tokens.text
        let bubbleFill = (widgetAppearance == .light ? NSColor.white : NSColor.black).withAlphaComponent(widgetAppearance == .light ? 0.92 : 0.72)
        let bubbleStroke = (widgetStyle == .terminal ? tokens.termBorder : tokens.controlBorder).withAlphaComponent(0.75)
        let hintAttrs = attrs(size: 10, weight: .semibold, color: textColor, mono: widgetStyle != .native)
        let textSize = hoverHint.size(withAttributes: hintAttrs)
        let bubbleWidth = textSize.width + 14
        let bubbleHeight = textSize.height + 8
        let screen = activeScreenRect
        let x = min(max(hoverHintRect.midX - bubbleWidth / 2, screen.minX), screen.maxX - bubbleWidth)
        let y = max(screen.minY + 2, hoverHintRect.minY - bubbleHeight - 5)
        let bubble = NSRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight)
        drawRounded(bubble, radius: 6, fill: bubbleFill, stroke: bubbleStroke)
        drawText(hoverHint, at: NSPoint(x: bubble.minX + 7, y: bubble.minY + 4), attrs: hintAttrs)
    }

    private func drawButton(rect: NSRect, symbol: String, fallback: String, tokens: WidgetTokens, color: NSColor, active: Bool = false, terminal: Bool = false, square: Bool = false) {
        let fill = active ? tokens.controlOn : (terminal || square ? .clear : tokens.controlBackground)
        let stroke = terminal ? tokens.termBorder : tokens.controlBorder
        let path = NSBezierPath(roundedRect: rect, xRadius: square ? 5 : rect.width / 2, yRadius: square ? 5 : rect.height / 2)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.stroke()

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: fallback) {
            let pointSize = rect.height <= 15 ? 8.6 : rect.height <= 17 ? 9.4 : 10.5
            let iconSize = rect.height <= 15 ? 9.5 : rect.height <= 17 ? 10.5 : 11.5
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: color)
            let config = sizeConfig.applying(colorConfig)
            let symbolImage = image.withSymbolConfiguration(config) ?? image
            let imageRect = NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize)
            symbolImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        let buttonAttrs = attrs(size: rect.height <= 18 ? 8 : 9, weight: .bold, color: color, mono: true)
        let size = fallback.size(withAttributes: buttonAttrs)
        drawText(fallback, at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), attrs: buttonAttrs)
    }

    private func drawLinearRow(_ row: CreditRow, y: CGFloat, rect: NSRect, tokens: WidgetTokens, accent: NSColor, height: CGFloat, radius: CGFloat, showPercentSymbol: Bool) {
        let labelWidth = labelColumnWidth
        let percentWidth = percentColumnWidth
        let resetWidth = resetColumnWidth
        let gap = columnGap
        let barX = rect.minX + labelWidth + gap
        let barWidth = progressBarWidth(in: rect)
        drawText(row.label, at: NSPoint(x: rect.minX, y: y - 4), attrs: attrs(size: 10.4, weight: .semibold, color: tokens.faint, mono: false))
        drawProgress(percent: row.percent, in: NSRect(x: barX, y: y, width: barWidth, height: height), fill: fillColor(row.percent, tokens: tokens), track: tokens.track, radius: radius)
        let percent = showPercentSymbol ? "\(row.percent)%" : "\(row.percent)"
        drawRight(percent, x: barX + barWidth + gap + percentWidth, y: y - 5, width: percentWidth, attrs: attrs(size: 10.8, weight: .bold, color: row.percent >= 95 ? tokens.warn : tokens.text, mono: false))
        drawRight(row.remaining, x: rect.maxX, y: y - 5, width: resetWidth, attrs: attrs(size: 9.8, weight: .regular, color: tokens.muted, mono: false))
    }

    private func drawMonoRow(_ row: CreditRow, y: CGFloat, rect: NSRect, tokens: WidgetTokens, accent: NSColor) {
        let barX = rect.minX + labelColumnWidth + columnGap
        let barWidth = progressBarWidth(in: rect)
        let percentRight = barX + barWidth + columnGap + percentColumnWidth
        drawText(row.label, at: NSPoint(x: rect.minX, y: y), attrs: attrs(size: 10.6, weight: .regular, color: tokens.muted, mono: true))
        drawSegmentBar(percent: row.percent, in: NSRect(x: barX, y: y + 1, width: barWidth, height: 10), count: max(12, Int(barWidth / 5.6)), fill: fillColor(row.percent, tokens: tokens), empty: tokens.track)
        drawRight("\(row.percent)%", x: percentRight, y: y, width: percentColumnWidth, attrs: attrs(size: 10.6, weight: .bold, color: row.percent >= 95 ? tokens.warn : tokens.text, mono: true))
        drawRight(row.remaining, x: rect.maxX, y: y, width: resetColumnWidth, attrs: attrs(size: 10.6, weight: .regular, color: tokens.muted, mono: true))
    }

    private func drawTerminalRow(_ row: CreditRow, y: CGFloat, rect: NSRect, tokens: WidgetTokens) {
        let barX = rect.minX + labelColumnWidth + columnGap
        let barWidth = progressBarWidth(in: rect)
        drawText(row.label, at: NSPoint(x: rect.minX, y: y - 1), attrs: attrs(size: 10.4, weight: .regular, color: tokens.termFaint, mono: true))
        let bar = NSRect(x: barX, y: y, width: barWidth, height: 8)
        drawDottedTrack(in: bar, tokens: tokens)
        let fill = fillColor(row.percent, tokens: tokens)
        fill.setFill()
        NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(row.percent) / 100, height: bar.height)).fill()
        tokens.termBorder.setStroke()
        NSBezierPath(rect: bar).stroke()
        drawRight("\(row.percent)%", x: bar.maxX + columnGap + percentColumnWidth, y: y - 2, width: percentColumnWidth, attrs: attrs(size: 10.4, weight: .bold, color: row.percent >= 95 ? tokens.termWarn : tokens.termText, mono: true))
        drawRight(row.remaining, x: rect.maxX, y: y - 2, width: resetColumnWidth, attrs: attrs(size: 10.4, weight: .regular, color: tokens.termDim, mono: true))
    }

    private func progressBarWidth(in rect: NSRect) -> CGFloat {
        rect.width - labelColumnWidth - percentColumnWidth - resetColumnWidth - columnGap * 3
    }

    private func drawProgress(percent: Int, in rect: NSRect, fill: NSColor, track: NSColor, radius: CGFloat) {
        drawRounded(rect, radius: radius, fill: track, stroke: .clear)
        let width = rect.width * CGFloat(max(0, min(percent, 100))) / 100
        if width > 0 {
            drawRounded(NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), radius: radius, fill: fill, stroke: .clear)
        }
    }

    private func drawBlockBar(percent: Int, at point: NSPoint, count: Int, fill: NSColor, empty: NSColor, fontSize: CGFloat = 12) {
        let filled = Int((Double(percent) / 100 * Double(count)).rounded())
        let on = String(repeating: "█", count: max(0, min(filled, count)))
        let off = String(repeating: "░", count: max(0, count - filled))
        let barAttrs = attrs(size: fontSize, weight: .regular, color: fill, mono: true)
        drawText(on, at: point, attrs: barAttrs)
        let onWidth = on.size(withAttributes: barAttrs).width
        drawText(off, at: NSPoint(x: point.x + onWidth, y: point.y), attrs: attrs(size: fontSize, weight: .regular, color: empty, mono: true))
    }

    private func drawSegmentBar(percent: Int, in rect: NSRect, count: Int, fill: NSColor, empty: NSColor) {
        let clampedCount = max(1, count)
        let filled = max(0, min(clampedCount, Int((Double(percent) / 100 * Double(clampedCount)).rounded())))
        let gap: CGFloat = 1
        let segmentWidth = max(1, (rect.width - CGFloat(clampedCount - 1) * gap) / CGFloat(clampedCount))

        for index in 0..<clampedCount {
            let x = rect.minX + CGFloat(index) * (segmentWidth + gap)
            let segment = NSRect(x: x, y: rect.minY, width: segmentWidth, height: rect.height)
            (index < filled ? fill : empty).setFill()
            NSBezierPath(rect: segment).fill()
        }
    }

    private func drawDottedTrack(in rect: NSRect, tokens: WidgetTokens) {
        tokens.termTrack.setFill()
        NSBezierPath(rect: rect).fill()
        tokens.termDot.setFill()
        for x in stride(from: rect.minX + 2, through: rect.maxX - 2, by: 3) {
            for y in stride(from: rect.minY + 2, through: rect.maxY - 2, by: 3) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 0.9, height: 0.9)).fill()
            }
        }
    }

    private func drawRounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        if stroke.alphaComponent > 0 {
            stroke.setStroke()
            path.stroke()
        }
    }

    private func drawSwatch(at point: NSPoint, color: NSColor, size: CGFloat = 8) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x, y: point.y, width: size, height: size), xRadius: 3, yRadius: 3).fill()
    }

    private func drawBadge(_ service: CreditService, at point: NSPoint, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x, y: point.y, width: 22, height: 22), xRadius: 7, yRadius: 7).fill()
        let mark = service.name.contains("Codex") ? "#" : "C"
        let markAttrs = attrs(size: 13, weight: .heavy, color: .white, mono: false)
        let size = mark.size(withAttributes: markAttrs)
        drawText(mark, at: NSPoint(x: point.x + 11 - size.width / 2, y: point.y + 11 - size.height / 2), attrs: markAttrs)
    }

    private func drawDashedLine(y: CGFloat, from minX: CGFloat, to maxX: CGFloat) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: minX, y: y))
        line.line(to: NSPoint(x: maxX, y: y))
        line.setLineDash([5, 4], count: 2, phase: 0)
        NSColor(calibratedWhite: 0.1, alpha: 0.45).setStroke()
        line.stroke()
    }

    private func drawLine(y: CGFloat, from minX: CGFloat, to maxX: CGFloat, color: NSColor) {
        color.setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: minX, y: y), to: NSPoint(x: maxX, y: y))
    }

    private func drawRight(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attrs)
        drawText(text, at: NSPoint(x: x - max(width, size.width), y: y), attrs: attrs)
    }

    private func fillColor(_ percent: Int, tokens: WidgetTokens) -> NSColor {
        if percent >= 90 {
            return tokens.warn
        }

        if percent > 50 {
            return .hex(0xe49a4b)
        }

        return tokens.codex
    }

    private func accent(for service: CreditService, tokens: WidgetTokens) -> NSColor {
        service.name.contains("Codex") ? tokens.codex : tokens.claude
    }

    private func displayName(for service: CreditService) -> String {
        service.name.contains("Codex") ? "Codex" : "Claude Code"
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))

        if seconds < 60 {
            return "just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(hours / 24)d ago"
    }

    private func shortTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date())
    }

    private func drawText(_ text: String, at point: NSPoint, attrs: [NSAttributedString.Key: Any]) {
        text.draw(at: point, withAttributes: attrs)
    }

    private func attrs(size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = true) -> [NSAttributedString.Key: Any] {
        [
            .font: mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let size = WidgetView.initialSize
        let view = WidgetView(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        let alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? false
        window.isMovableByWindowBackground = true
        WidgetView.applyWindowBehavior(to: window, alwaysOnTop: alwaysOnTop)
        window.setFrame(topLeftFrame(for: size), display: true)
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    private func topLeftFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 12

        return NSRect(
            x: visibleFrame.minX + margin,
            y: visibleFrame.maxY - size.height - margin,
            width: size.width,
            height: size.height
        )
    }
}

if CommandLine.arguments.contains("--debug-data") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(CreditStore().load()),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
