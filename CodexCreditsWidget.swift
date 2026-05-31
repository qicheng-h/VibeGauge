import AppKit
import Foundation

struct CreditData: Codable {
    var services: [CreditService]
}

struct CreditService: Codable {
    var name: String
    var rows: [CreditRow]
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

final class CreditStore {
    private let claudeReader = ClaudeRateLimitReader()
    private let codexReader = CodexRateLimitReader()
    private let fallback = CreditData(services: [
        CreditService(name: "Claude Code", rows: [
            CreditRow(label: "5h", percent: 0, remaining: "no data"),
            CreditRow(label: "7d", percent: 0, remaining: "no data"),
        ]),
        CreditService(name: "OpenAI Codex", rows: [
            CreditRow(label: "5h", percent: 0, remaining: "no data"),
            CreditRow(label: "7d", percent: 0, remaining: "no data"),
        ]),
    ])

    func load() -> CreditData {
        var data = fallback

        if let claudeRows = claudeReader.loadRows() {
            data.services[0].rows = claudeRows
        }

        if let codexRows = codexReader.loadRows(signature: sourceSignature()) {
            data.services[1].rows = codexRows
        }

        return data
    }

    func sourceSignature() -> String {
        [
            fileSignature(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codex-credits-status.json")),
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

final class ClaudeRateLimitReader {
    private let fileManager = FileManager.default
    private let cacheReader = ClaudeUsageCacheReader()
    private var capturedAt: Date = .distantPast

    func loadRows() -> [CreditRow]? {
        let cacheSnapshot = cacheReader.loadSnapshot()
        let statusSnapshot = statusLineSnapshot()

        switch (cacheSnapshot, statusSnapshot) {
        case let (cache?, status?):
            return status.modified >= cache.modified ? status.rows : cache.rows
        case let (cache?, nil):
            return cache.rows
        case let (nil, status?):
            return status.rows
        case (nil, nil):
            return nil
        }
    }

    private func statusLineSnapshot() -> ClaudeRowsSnapshot? {
        let file = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/codex-credits-status.json")

        capturedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()

        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else {
            return nil
        }

        var rows: [CreditRow] = []

        if let current = firstLimit(in: limits, keys: ["current_session", "currentSession", "session", "five_hour", "fiveHour", "primary"]) {
            rows.append(row(from: current, label: "5h"))
        }

        if let weekly = firstLimit(in: limits, keys: ["weekly", "weekly_limits", "weeklyLimits", "all_models", "allModels", "seven_day", "sevenDay", "secondary"]) {
            rows.append(row(from: weekly, label: "7d"))
        }

        return rows.isEmpty ? nil : ClaudeRowsSnapshot(rows: rows, modified: capturedAt)
    }

    func sourceSignature() -> String {
        cacheReader.sourceSignature() + "|" + fileSignature(
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/codex-credits-status.json")
        )
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
            return ResetDisplay(remaining: "refreshing", expired: true)
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

final class ClaudeUsageCacheReader {
    private let fileManager = FileManager.default
    private let maxCacheFileSize = 8 * 1024 * 1024
    private let zstdMagic = Data([0x28, 0xb5, 0x2f, 0xfd])

    fileprivate func loadSnapshot() -> ClaudeRowsSnapshot? {
        for file in usageCacheFiles() {
            guard let data = try? Data(contentsOf: file),
                  data.count <= maxCacheFileSize,
                  data.range(of: Data("claude.ai/api/organizations".utf8)) != nil,
                  data.range(of: Data("/usage".utf8)) != nil,
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
        guard let file = newestUsageCacheFile(),
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
                  data.range(of: Data("claude.ai/api/organizations".utf8)) != nil,
                  data.range(of: Data("/usage".utf8)) != nil else {
                continue
            }

            return file
        }

        return nil
    }

    private func decodeCachedUsagePayload(from data: Data) -> [String: Any]? {
        guard let magicRange = data.range(of: zstdMagic) else {
            return nil
        }

        let httpMarker = Data("HTTP/1.1".utf8)
        let searchStart = magicRange.upperBound
        let searchRange = searchStart..<data.endIndex
        let bodyEnd = data.range(of: httpMarker, options: [], in: searchRange)?.lowerBound ?? data.endIndex
        guard bodyEnd > magicRange.lowerBound else {
            return nil
        }

        let compressed = data.subdata(in: magicRange.lowerBound..<bodyEnd)
        guard let jsonData = zstdDecode(compressed),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        return object
    }

    private func zstdDecode(_ data: Data) -> Data? {
        guard let zstd = zstdExecutable() else {
            return nil
        }

        let process = Process()
        process.executableURL = zstd
        process.arguments = ["-dc", "-"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            input.fileHandleForWriting.write(data)
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let decoded = output.fileHandleForReading.readDataToEndOfFile()
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
            return ResetDisplay(remaining: "refreshing", expired: true)
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
    let payload: CodexPayload?
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

final class CodexRateLimitReader {
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private var cachedSignature: String?
    private var cachedLimits: CodexRateLimits?

    func loadRows(signature: String) -> [CreditRow]? {
        let limits: CodexRateLimits?

        if cachedSignature == signature {
            limits = cachedLimits
        } else {
            limits = latestRateLimits()
            cachedLimits = limits
            cachedSignature = signature
        }

        guard let limits else {
            return nil
        }

        var rows: [CreditRow] = []

        if let primary = limits.primary {
            rows.append(row(from: primary, fallbackLabel: "5h"))
        }

        if let secondary = limits.secondary {
            rows.append(row(from: secondary, fallbackLabel: "7d"))
        }

        return rows.isEmpty ? nil : rows
    }

    private func latestRateLimits() -> CodexRateLimits? {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            home.appendingPathComponent(".codex/sessions"),
            home.appendingPathComponent(".codex/archived_sessions"),
        ]

        for file in recentJSONLFiles(roots: roots) {
            if let limits = latestRateLimits(in: file) {
                return limits
            }
        }

        return nil
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

    private func latestRateLimits(in file: URL) -> CodexRateLimits? {
        guard let data = tailData(from: file, maxBytes: 4 * 1024 * 1024) else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let eventData = String(line).data(using: .utf8),
               let event = try? decoder.decode(CodexLogEvent.self, from: eventData),
               let limits = event.payload?.rate_limits {
                return limits
            }
        }

        return nil
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
            return ResetDisplay(remaining: "refreshing", expired: true)
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
        switch self {
        case .native: return NSSize(width: 332, height: 152)
        case .mono: return NSSize(width: 292, height: 132)
        case .terminal: return NSSize(width: 306, height: 136)
        }
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
    private var creditData: CreditData
    private var timer: Timer?
    private var sourceCheckCounter = 0
    private var sourceSignature: String
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

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        self.creditData = store.load()
        self.sourceSignature = store.sourceSignature()
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
    }

    required init?(coder: NSCoder) {
        self.creditData = store.load()
        self.sourceSignature = store.sourceSignature()
        self.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? false
        self.widgetStyle = Self.storedStyle()
        self.widgetAppearance = Self.storedAppearance()
        super.init(coder: coder)
        updateTooltips()
    }

    deinit {
        timer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    func reload() {
        creditData = store.load()
        sourceSignature = store.sourceSignature()
        needsDisplay = true
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

        if sourceCheckCounter >= 4 {
            let nextSignature = store.sourceSignature()
            if nextSignature != sourceSignature {
                sourceSignature = nextSignature
            }
            sourceCheckCounter = 0
        }

        creditData = store.load()
        needsDisplay = true
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
        switch widgetStyle {
        case .native: return 17
        case .mono: return 15
        case .terminal: return 15
        }
    }

    private var controlGap: CGFloat {
        switch widgetStyle {
        case .native: return 4
        case .mono, .terminal: return 3
        }
    }

    private func drawNativeWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: 14, dy: 10)
        drawRounded(rect, radius: 16, fill: tokens.nativeBackground, stroke: tokens.nativeBorder)
        drawHeader(in: screenRect, tokens: tokens, titleSize: 13.2, timePrefix: "")

        var y = screenRect.maxY - 34
        for service in creditData.services {
            let accent = accent(for: service, tokens: tokens)
            drawSwatch(at: NSPoint(x: screenRect.minX, y: y + 3), color: accent, size: 7)
            drawText(service.name, at: NSPoint(x: screenRect.minX + 12, y: y), attrs: attrs(size: 11.5, weight: .bold, color: tokens.text, mono: false))
            y -= 17

            for row in service.rows {
                drawLinearRow(row, y: y, rect: screenRect, tokens: tokens, accent: accent, height: 5, radius: 3.5, showPercentSymbol: true)
                y -= 18
            }
        }
    }

    private func drawMonoWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: 12, dy: 10)
        drawRounded(rect, radius: 9, fill: tokens.monoBackground, stroke: tokens.monoBorder)
        drawHeader(in: screenRect, tokens: tokens, titleSize: 11.2, timePrefix: "", title: "plan_usage", mono: true)

        var y = screenRect.maxY - 29
        for service in creditData.services {
            let accent = accent(for: service, tokens: tokens)
            drawText(shortName(for: service).lowercased() + " >", at: NSPoint(x: screenRect.minX, y: y), attrs: attrs(size: 10.8, weight: .bold, color: accent, mono: true))
            y -= 15
            for row in service.rows {
                drawMonoRow(row, y: y, rect: screenRect, tokens: tokens, accent: accent)
                y -= 16
            }
        }
    }

    private func drawTerminalWidget(in rect: NSRect, tokens: WidgetTokens) {
        screenRect = rect.insetBy(dx: 11, dy: 9)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGradient(colors: [tokens.termBackgroundTop, tokens.termBackgroundBottom])?.draw(in: path, angle: -35)
        tokens.termBorder.setStroke()
        path.stroke()
        drawHeader(in: screenRect, tokens: tokens, titleSize: 11.5, timePrefix: "", terminal: true)

        var y = screenRect.maxY - 27
        var previousBottom: CGFloat?
        for (index, service) in creditData.services.enumerated() {
            if index > 0 {
                if let previousBottom {
                    drawLine(y: (previousBottom + y) / 2 + 1, from: screenRect.minX, to: screenRect.maxX, color: tokens.termHair)
                }
                y -= 6
            }
            drawText(service.name, at: NSPoint(x: screenRect.minX, y: y), attrs: attrs(size: 10.6, weight: .bold, color: tokens.termDim, mono: true))
            y -= 13
            for row in service.rows {
                drawTerminalRow(row, y: y, rect: screenRect, tokens: tokens)
                previousBottom = y
                y -= 15
            }
        }
    }

    private func drawHeader(in rect: NSRect, tokens: WidgetTokens, titleSize: CGFloat, timePrefix: String, title: String = "Plan Usage", mono: Bool = false, terminal: Bool = false) {
        let text = terminal ? tokens.termText : tokens.text
        let muted = terminal ? tokens.termDim : tokens.faint
        drawText(title, at: NSPoint(x: rect.minX, y: rect.maxY - titleSize - 1), attrs: attrs(size: titleSize, weight: .heavy, color: text, mono: mono || terminal))
        let time = timePrefix + shortTimeString()
        let timeAttrs = attrs(size: terminal ? 10.2 : 10.5, weight: .semibold, color: muted, mono: mono || terminal)
        let timeSize = time.size(withAttributes: timeAttrs)
        drawText(time, at: NSPoint(x: styleButtonRect.minX - timeSize.width - 7, y: rect.maxY - titleSize - 1), attrs: timeAttrs)
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
        let labelWidth: CGFloat = 22
        let percentWidth: CGFloat = 34
        let resetWidth: CGFloat = 44
        let gap: CGFloat = 8
        let barX = rect.minX + labelWidth + gap
        let barWidth = rect.width - labelWidth - percentWidth - resetWidth - gap * 3
        drawText(row.label, at: NSPoint(x: rect.minX, y: y - 4), attrs: attrs(size: 10.4, weight: .semibold, color: tokens.faint, mono: false))
        drawProgress(percent: row.percent, in: NSRect(x: barX, y: y, width: barWidth, height: height), fill: fillColor(row.percent, accent: accent, warn: tokens.warn), track: tokens.track, radius: radius)
        let percent = showPercentSymbol ? "\(row.percent)%" : "\(row.percent)"
        drawRight(percent, x: barX + barWidth + gap + percentWidth, y: y - 5, width: percentWidth, attrs: attrs(size: 10.8, weight: .bold, color: row.percent >= 95 ? tokens.warn : tokens.text, mono: false))
        drawRight(row.remaining, x: rect.maxX, y: y - 5, width: resetWidth, attrs: attrs(size: 9.8, weight: .regular, color: tokens.muted, mono: false))
    }

    private func drawMonoRow(_ row: CreditRow, y: CGFloat, rect: NSRect, tokens: WidgetTokens, accent: NSColor) {
        let labelWidth: CGFloat = 24
        let percentWidth: CGFloat = 26
        let resetWidth: CGFloat = 43
        let labelGap: CGFloat = 7
        let percentGap: CGFloat = 8
        let resetGap: CGFloat = 8
        let barX = rect.minX + labelWidth + labelGap
        let barWidth = rect.width - labelWidth - percentWidth - resetWidth - labelGap - percentGap - resetGap
        let percentRight = barX + barWidth + percentGap + percentWidth
        let resetRight = percentRight + resetGap + resetWidth
        drawText(row.label, at: NSPoint(x: rect.minX, y: y), attrs: attrs(size: 10.6, weight: .regular, color: tokens.muted, mono: true))
        drawSegmentBar(percent: row.percent, in: NSRect(x: barX, y: y + 1, width: barWidth, height: 10), count: max(12, Int(barWidth / 5.6)), fill: fillColor(row.percent, accent: accent, warn: tokens.warn), empty: tokens.track)
        drawRight("\(row.percent)", x: percentRight, y: y, width: percentWidth, attrs: attrs(size: 10.6, weight: .bold, color: row.percent >= 95 ? tokens.warn : tokens.text, mono: true))
        drawRight(tightDuration(row.remaining), x: resetRight, y: y, width: resetWidth, attrs: attrs(size: 10.6, weight: .regular, color: tokens.muted, mono: true))
    }

    private func drawTerminalRow(_ row: CreditRow, y: CGFloat, rect: NSRect, tokens: WidgetTokens) {
        let labelWidth: CGFloat = 20
        let percentWidth: CGFloat = 32
        let resetWidth: CGFloat = 42
        let gap: CGFloat = 5
        let barX = rect.minX + labelWidth + gap
        let barWidth = rect.width - labelWidth - percentWidth - resetWidth - gap * 3
        drawText(row.label, at: NSPoint(x: rect.minX, y: y - 1), attrs: attrs(size: 10.4, weight: .regular, color: tokens.termFaint, mono: true))
        let bar = NSRect(x: barX, y: y, width: barWidth, height: 8)
        drawDottedTrack(in: bar, tokens: tokens)
        let fill = row.percent >= 95 ? tokens.termWarn : tokens.termFill
        fill.setFill()
        NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(row.percent) / 100, height: bar.height)).fill()
        tokens.termBorder.setStroke()
        NSBezierPath(rect: bar).stroke()
        drawRight("\(row.percent)%", x: bar.maxX + gap + percentWidth, y: y - 2, width: percentWidth, attrs: attrs(size: 10.4, weight: .bold, color: row.percent >= 95 ? tokens.termWarn : tokens.termText, mono: true))
        drawRight(row.remaining, x: rect.maxX, y: y - 2, width: resetWidth, attrs: attrs(size: 10.4, weight: .regular, color: tokens.termDim, mono: true))
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

    private func fillColor(_ percent: Int, accent: NSColor, warn: NSColor) -> NSColor {
        percent >= 95 ? warn : accent
    }

    private func accent(for service: CreditService, tokens: WidgetTokens) -> NSColor {
        service.name.contains("Codex") ? tokens.codex : tokens.claude
    }

    private func shortName(for service: CreditService) -> String {
        service.name.contains("Codex") ? "Codex" : "Claude"
    }

    private func shortTimeString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date())
    }

    private func tightDuration(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "")
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
