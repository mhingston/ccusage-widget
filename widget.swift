import SwiftUI
import WidgetKit
import AppIntents

struct ClaudeDaily: Codable {
    var totals: ClaudeTotals = .init()
}

struct ClaudeTotals: Codable {
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
}

struct ClaudeDailyResponse: Codable { var totals: ClaudeTotals = .init() }

struct ClaudeSessionResponse: Codable {
    var sessions: [ClaudeSession] = []
}

struct ClaudeSession: Codable, Identifiable {
    var sessionId: String
    var projectPath: String = ""
    var title: String?
    var workingDirectory: String?
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var lastActivity: String = ""
    var id: String { sessionId }
}

struct ClaudeWidgetSnapshot: Codable {
    var generatedAt: Date
    var totals: ClaudeTotals
    var sessions: [ClaudeSession]
}

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let totals: ClaudeTotals
    let sessions: [ClaudeSession]
    let sessionPage: Int
    let error: String?
}

struct ClaudeUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(), totals: ClaudeTotals(totalTokens: 1_240_000, totalCost: 4.82, inputTokens: 20_000, outputTokens: 8_000, cacheReadTokens: 1_212_000), sessions: [], sessionPage: 0, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        Task {
            let entry: ClaudeUsageEntry
            do {
                let snapshot = try Self.loadSnapshot()
                let pageCount = max(1, Int(ceil(Double(snapshot.sessions.count) / 2.0)))
                let page = min(UserDefaults.standard.integer(forKey: "sessionPage"), pageCount - 1)
                entry = ClaudeUsageEntry(date: snapshot.generatedAt, totals: snapshot.totals, sessions: snapshot.sessions, sessionPage: page, error: nil)
            } catch {
                entry = ClaudeUsageEntry(date: Date(), totals: .init(), sessions: [], sessionPage: 0, error: error.localizedDescription)
            }
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private static func loadSnapshot() throws -> ClaudeWidgetSnapshot {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "CCUsageSnapshotPath") as? String, !path.isEmpty else {
            throw NSError(domain: "ClaudeUsageWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Snapshot path is not configured"])
        }
        let url = URL(fileURLWithPath: path)
        return try JSONDecoder().decode(ClaudeWidgetSnapshot.self, from: Data(contentsOf: url))
    }

    private static func today() -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func run(_ command: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let p = Process(); let out = Pipe(); let err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", command]
            p.standardOutput = out; p.standardError = err
            do {
                try p.run(); p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if p.terminationStatus == 0 { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "ccusage", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ccusage failed"])) }
            } catch { continuation.resume(throwing: error) }
        }
    }
}

struct ClaudeUsageWidgetView: View {
    let entry: ClaudeUsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemMedium { mediumView } else { smallView }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CLAUDE CODE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                updatedTime
                Button(intent: RefreshWidgetIntent()) { Image(systemName: "sparkles") }
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Refresh usage")
            }
            Text(entry.totals.totalTokens.compactTokens).font(.system(size: 30, weight: .bold, design: .rounded))
            Text("tokens today").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(entry.totals.totalCost, format: .currency(code: "USD"))
                Spacer()
                Text("\(entry.sessions.count) sessions")
            }.font(.caption.weight(.medium))
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CLAUDE CODE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                updatedTime
                if entry.sessions.count > 2 {
                    Button(intent: PreviousSessionPageIntent()) { Image(systemName: "chevron.left") }
                        .disabled(entry.sessionPage == 0)
                    Text("\(entry.sessionPage + 1)/\(sessionPageCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button(intent: NextSessionPageIntent()) { Image(systemName: "chevron.right") }
                        .disabled(entry.sessionPage >= sessionPageCount - 1)
                }
                Button(intent: RefreshWidgetIntent()) { Image(systemName: "sparkles") }
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Refresh usage")
            }
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(entry.totals.totalTokens.compactTokens).font(.system(size: 31, weight: .bold, design: .rounded))
                Text("tokens today").font(.caption).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(entry.totals.totalCost, format: .currency(code: "USD"))
                    Text("\(entry.sessions.count) sessions").foregroundStyle(.secondary)
                }.font(.caption.weight(.medium))
            }
            Divider()
            ForEach(Array(entry.sessions.dropFirst(entry.sessionPage * 2).prefix(2))) { session in
                Link(destination: session.resumeURL) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.displayTitle).lineLimit(1).fontWeight(.semibold)
                            Text("\(session.directoryDisplay) · \(session.lastActivityText)").lineLimit(1).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(session.totalTokens.compactTokens).monospacedDigit().fontWeight(.semibold)
                            Text(session.totalCost, format: .currency(code: "USD")).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .font(.caption2)
                .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private var sessionPageCount: Int { max(1, Int(ceil(Double(entry.sessions.count) / 2.0))) }

    private var updatedTime: some View {
        Text(entry.date, format: .dateTime.hour().minute())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Updated \(entry.date.formatted(date: .omitted, time: .shortened))")
    }
}

struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh usage"
    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeUsageWidget")
        return .result()
    }
}

struct PreviousSessionPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous sessions"
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(max(0, defaults.integer(forKey: "sessionPage") - 1), forKey: "sessionPage")
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeUsageWidget")
        return .result()
    }
}

struct NextSessionPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Next sessions"
    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "sessionPage") + 1, forKey: "sessionPage")
        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeUsageWidget")
        return .result()
    }
}

@main
struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeUsageProvider()) { entry in ClaudeUsageWidgetView(entry: entry) }
            .configurationDisplayName("Claude Code Usage")
            .description("Today's Claude Code token usage and session breakdown.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension ClaudeSession {
    var resumeURL: URL {
        var components = URLComponents()
        components.scheme = "ccusage-widget"
        components.host = "resume"
        components.queryItems = [
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "directory", value: workingDirectory)
        ]
        return components.url!
    }

    var displayTitle: String {
        guard let title, !title.isEmpty else { return projectName }
        return title
    }

    var projectName: String {
        let cleaned = projectPath.replacingOccurrences(of: "-Users-", with: "").replacingOccurrences(of: "-", with: " ")
        return cleaned.split(separator: " ").last.map(String.init) ?? "Claude session"
    }

    var directoryDisplay: String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return projectName }
        let components = workingDirectory.split(separator: "/", omittingEmptySubsequences: true)
        let home = components.count >= 2 && components[0] == "Users" ? "/Users/\(components[1])" : ""
        if workingDirectory == home { return "~" }
        if !home.isEmpty, workingDirectory.hasPrefix(home + "/") { return "~" + workingDirectory.dropFirst(home.count) }
        return workingDirectory
    }

    var lastActivityText: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: lastActivity) else { return "" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

extension Int {
    var compactTokens: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return String(self)
    }
}
