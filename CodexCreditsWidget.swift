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

final class CreditStore {
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

        if let claudeRows = ClaudeRateLimitReader().loadRows() {
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

    func loadRows() -> [CreditRow]? {
        let file = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/codex-credits-status.json")

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

        return rows.isEmpty ? nil : rows
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
        let remaining = resetLabel(from: limit)

        return CreditRow(label: label, percent: max(0, min(percent, 100)), remaining: remaining)
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

    private func resetLabel(from limit: [String: Any]) -> String {
        if let seconds = number(in: limit, keys: ["reset_in_seconds", "seconds_until_reset", "remaining_seconds"]) {
            return countdown(seconds: Int(seconds))
        }

        if let timestamp = number(in: limit, keys: ["resets_at", "reset_at", "resetsAt", "resetAt"]) {
            return resetCountdown(until: timestamp)
        }

        for key in ["remaining", "reset_in", "resets_in", "reset_label", "resetLabel"] {
            if let value = limit[key] as? String, !value.isEmpty {
                return normalizeDurationLabel(value)
            }
        }

        for key in ["resets_at", "reset_at", "resetsAt", "resetAt"] {
            if let value = limit[key] as? String, !value.isEmpty {
                if let date = ISO8601DateFormatter().date(from: value) {
                    return resetCountdown(until: date.timeIntervalSince1970)
                }

                return value
            }
        }

        return "no reset"
    }

    private func resetCountdown(until timestamp: TimeInterval) -> String {
        let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))
        return countdown(seconds: seconds)
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
        let remaining = resetCountdown(until: limit.resets_at)

        return CreditRow(label: label, percent: max(0, min(percent, 100)), remaining: remaining)
    }

    private func resetCountdown(until timestamp: TimeInterval?) -> String {
        guard let timestamp else {
            return "no reset"
        }

        let seconds = max(0, Int(timestamp - Date().timeIntervalSince1970))

        if seconds == 0 {
            return "now"
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }

        return "\(hours)h \(minutes)m"
    }
}

final class WidgetView: NSView {
    private static let alwaysOnTopKey = "alwaysOnTop"
    private let store = CreditStore()
    private var creditData: CreditData
    private var timer: Timer?
    private var sourceSignature: String
    private var alwaysOnTop: Bool
    private var screenRect: NSRect = .zero
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d h:mm a"
        return formatter
    }()

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        self.creditData = store.load()
        self.sourceSignature = store.sourceSignature()
        self.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        super.init(frame: frameRect)
        wantsLayer = true
        let refreshTimer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            self?.reloadIfSourcesChanged()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer
    }

    required init?(coder: NSCoder) {
        self.creditData = store.load()
        self.sourceSignature = store.sourceSignature()
        self.alwaysOnTop = UserDefaults.standard.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        super.init(coder: coder)
    }

    deinit {
        timer?.invalidate()
    }

    func reload() {
        creditData = store.load()
        sourceSignature = store.sourceSignature()
        needsDisplay = true
    }

    private func reloadIfSourcesChanged() {
        let nextSignature = store.sourceSignature()

        if nextSignature != sourceSignature {
            sourceSignature = nextSignature
        }

        creditData = store.load()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let topItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        topItem.state = alwaysOnTop ? .on : .off
        menu.addItem(topItem)
        menu.addItem(withTitle: "Refresh", action: #selector(reloadFromMenu), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if closeButtonRect.contains(point) {
            NSApplication.shared.terminate(nil)
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

        window?.performDrag(with: event)
    }

    @objc private func reloadFromMenu() {
        reload()
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey)
        window?.level = alwaysOnTop ? .floating : .normal
        needsDisplay = true
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

        let caseBounds = self.bounds.insetBy(dx: 7, dy: 7)
        drawCase(in: caseBounds)

        let screen = caseBounds.insetBy(dx: 7, dy: 7)
        screenRect = screen
        drawLCD(in: screen)
        drawWindowButtons()
        drawContent(in: screen.insetBy(dx: 10, dy: 8))
    }

    private var closeButtonRect: NSRect {
        let screen = activeScreenRect
        return NSRect(x: screen.maxX - 18, y: screen.maxY - 20, width: 13, height: 13)
    }

    private var refreshButtonRect: NSRect {
        let screen = activeScreenRect
        return NSRect(x: screen.maxX - 36, y: screen.maxY - 20, width: 13, height: 13)
    }

    private var topButtonRect: NSRect {
        let screen = activeScreenRect
        return NSRect(x: screen.maxX - 54, y: screen.maxY - 20, width: 13, height: 13)
    }

    private var activeScreenRect: NSRect {
        if screenRect == .zero {
            return bounds.insetBy(dx: 14, dy: 14)
        }

        return screenRect
    }

    private func drawWindowButtons() {
        let buttonAttrs = attrs(size: 8, weight: .bold, color: NSColor(calibratedWhite: 0.12, alpha: 1))

        drawButton(rect: topButtonRect, label: "^", attrs: buttonAttrs, active: alwaysOnTop)
        drawButton(rect: refreshButtonRect, label: "r", attrs: buttonAttrs)
        drawButton(rect: closeButtonRect, label: "x", attrs: buttonAttrs)
    }

    private func drawButton(rect: NSRect, label: String, attrs: [NSAttributedString.Key: Any], active: Bool = false) {
        let path = NSBezierPath(ovalIn: rect)
        let fill = active
            ? NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.39, alpha: 0.9)
            : NSColor(calibratedRed: 0.68, green: 0.72, blue: 0.62, alpha: 0.75)
        fill.setFill()
        path.fill()
        NSColor(calibratedWhite: 0.08, alpha: 0.45).setStroke()
        path.stroke()

        let size = label.size(withAttributes: attrs)
        drawText(label, at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), attrs: attrs)
    }

    private func drawCase(in rect: NSRect) {
        let casePath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.88, green: 0.84, blue: 0.75, alpha: 1),
            NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.47, alpha: 1),
        ])?.draw(in: casePath, angle: -35)

        NSColor(calibratedWhite: 0.22, alpha: 0.35).setStroke()
        casePath.lineWidth = 1.5
        casePath.stroke()
    }

    private func drawLCD(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(calibratedRed: 0.72, green: 0.77, blue: 0.66, alpha: 1).setFill()
        path.fill()

        NSColor(calibratedWhite: 0.08, alpha: 0.45).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        NSColor(calibratedWhite: 0.0, alpha: 0.06).setStroke()
        for y in stride(from: rect.minY + 3, through: rect.maxY - 3, by: 3) {
            NSBezierPath.strokeLine(from: NSPoint(x: rect.minX + 2, y: y), to: NSPoint(x: rect.maxX - 2, y: y))
        }
    }

    private func drawContent(in rect: NSRect) {
        let titleAttrs = attrs(size: 13, weight: .bold, color: .black)
        let smallAttrs = attrs(size: 10.5, weight: .regular, color: NSColor(calibratedWhite: 0.13, alpha: 1))
        let serviceAttrs = attrs(size: 10.5, weight: .semibold, color: NSColor(calibratedWhite: 0.25, alpha: 1))

        drawText("Plan Usage", at: NSPoint(x: rect.minX, y: rect.maxY - 15), attrs: titleAttrs)
        let time = dateFormatter.string(from: Date())
        let timeSize = time.size(withAttributes: smallAttrs)
        drawText(time, at: NSPoint(x: rect.maxX - timeSize.width - 62, y: rect.maxY - 14), attrs: smallAttrs)

        var y = rect.maxY - 34
        for (serviceIndex, service) in creditData.services.enumerated() {
            if serviceIndex > 0 {
                drawDashedLine(y: y + 14, from: rect.minX, to: rect.maxX)
            }

            drawText(service.name, at: NSPoint(x: rect.minX, y: y), attrs: serviceAttrs)
            y -= 18

            for row in service.rows {
                drawRow(row, y: y, rect: rect, attrs: smallAttrs)
                y -= 19
            }

            y -= 8
        }
    }

    private func drawRow(_ row: CreditRow, y: CGFloat, rect: NSRect, attrs: [NSAttributedString.Key: Any]) {
        let labelWidth: CGFloat = 27
        let percentWidth: CGFloat = 39
        let remainingWidth: CGFloat = 72
        let gap: CGFloat = 6
        let barX = rect.minX + labelWidth + gap
        let barWidth = rect.width - labelWidth - percentWidth - remainingWidth - gap * 3
        let barRect = NSRect(x: barX, y: y, width: barWidth, height: 13)

        drawText(row.label, at: NSPoint(x: rect.minX, y: y), attrs: attrs)
        drawBar(percent: row.percent, in: barRect)
        drawText("\(row.percent)%", at: NSPoint(x: barRect.maxX + gap, y: y - 1), attrs: attrs)
        drawText(row.remaining, at: NSPoint(x: rect.maxX - remainingWidth, y: y), attrs: attrs)
    }

    private func drawBar(percent: Int, in rect: NSRect) {
        NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()

        let fillWidth = rect.width * CGFloat(max(0, min(percent, 100))) / 100
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        let fillColor = percent >= 95
            ? NSColor(calibratedRed: 0.40, green: 0.22, blue: 0.18, alpha: 1)
            : NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.14, alpha: 1)
        fillColor.setFill()
        NSBezierPath(rect: fillRect).fill()

        NSColor(calibratedWhite: 0.05, alpha: 0.65).setStroke()
        NSBezierPath(rect: rect).stroke()

        NSColor(calibratedWhite: 0.0, alpha: 0.35).setFill()
        for x in stride(from: rect.minX + 4, through: rect.maxX - 2, by: 6) {
            for y in stride(from: rect.minY + 3, through: rect.maxY - 2, by: 5) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.1, height: 1.1)).fill()
            }
        }
    }

    private func drawDashedLine(y: CGFloat, from minX: CGFloat, to maxX: CGFloat) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: minX, y: y))
        line.line(to: NSPoint(x: maxX, y: y))
        line.setLineDash([5, 4], count: 2, phase: 0)
        NSColor(calibratedWhite: 0.1, alpha: 0.45).setStroke()
        line.stroke()
    }

    private func drawText(_ text: String, at point: NSPoint, attrs: [NSAttributedString.Key: Any]) {
        text.draw(at: point, withAttributes: attrs)
    }

    private func attrs(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let view = WidgetView(frame: NSRect(x: 0, y: 0, width: 380, height: 176))
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
        let alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true
        window.level = alwaysOnTop ? .floating : .normal
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrameAutosaveName("CodexCreditsWidget")
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
