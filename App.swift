import SwiftUI
import AppKit
import WidgetKit

struct UsageTotals: Codable {
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
}

struct DailyResponse: Decodable {
    var daily: [DailyRow] = []
    var totals: UsageTotals = .init()
}

struct DailyRow: Decodable {
    var period: String = ""
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0

    enum CodingKeys: String, CodingKey { case period, date, totalTokens, totalCost, inputTokens, outputTokens, cacheReadTokens }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decodeIfPresent(String.self, forKey: .period)
            ?? c.decodeIfPresent(String.self, forKey: .date) ?? ""
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
    }
}

struct SessionResponse: Decodable {
    var session: [SessionRow] = []
    enum CodingKeys: String, CodingKey { case session, sessions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent([SessionRow].self, forKey: .session)
            ?? c.decodeIfPresent([SessionRow].self, forKey: .sessions) ?? []
    }
}

struct SessionRow: Decodable, Identifiable {
    var agent: String = ""
    var period: String = ""
    var projectPath: String = ""
    var title: String = ""
    var workingDirectory: String = ""
    var totalTokens: Int = 0
    var totalCost: Double = 0
    var outputTokens: Int = 0
    var metadata: SessionMetadata?
    var id: String { period }

    enum CodingKeys: String, CodingKey { case agent, period, projectPath, totalTokens, totalCost, outputTokens, metadata, sessionId, lastActivity }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        let sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "session"
        let lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? sessionId
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        metadata = try c.decodeIfPresent(SessionMetadata.self, forKey: .metadata)
            ?? (lastActivity.map { SessionMetadata(lastActivity: $0) })
    }
}

struct SessionMetadata: Codable { var lastActivity: String? }

struct WidgetSessionSnapshot: Codable {
    var sessionId: String
    var projectPath: String
    var title: String
    var workingDirectory: String
    var totalTokens: Int
    var totalCost: Double
    var lastActivity: String
}

struct WidgetUsageSnapshot: Codable {
    var generatedAt: Date
    var totals: UsageTotals
    var sessions: [WidgetSessionSnapshot]
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var daily = UsageTotals()
    @Published var sessions: [SessionRow] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?

    private var refreshTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        Task.detached { [weak self] in
            do {
                let date = Self.today()
                async let daily = Self.run("ccusage claude daily --json --since \(date) --until \(date) --no-color")
                async let session = Self.run("ccusage claude session --json --no-color")
                let decoder = JSONDecoder()
                let dailyData = try await decoder.decode(DailyResponse.self, from: daily)
                let sessionData = try await decoder.decode(SessionResponse.self, from: session)
                let enrichedSessions = sessionData.session
                    .filter { $0.metadata?.lastActivity?.hasPrefix(date) == true }
                    .map { row in
                        var row = row
                        let details = Self.sessionDetails(projectPath: row.projectPath, sessionID: row.period)
                        row.title = details.title ?? ""
                        row.workingDirectory = details.cwd ?? ""
                        return row
                    }
                    .sorted { $0.period > $1.period }
                try Self.writeWidgetSnapshot(totals: dailyData.totals, sessions: enrichedSessions)
                let shouldReloadWidget = Self.shouldReloadWidget(sessionIDs: enrichedSessions.map(\.period))
                await MainActor.run {
                    self?.daily = dailyData.totals
                    self?.sessions = enrichedSessions
                    self?.lastUpdated = Date()
                    self?.isLoading = false
                    if shouldReloadWidget {
                        WidgetCenter.shared.reloadTimelines(ofKind: "ClaudeUsageWidget")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.error = error.localizedDescription
                    self?.isLoading = false
                }
            }
        }
    }

    nonisolated private static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    nonisolated private static func sessionDetails(projectPath: String, sessionID: String) -> (title: String?, cwd: String?) {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectPath)
            .appendingPathComponent("\(sessionID).jsonl")
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return (nil, nil) }
        var firstPrompt: String?
        var cwd: String?
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if cwd == nil { cwd = object["cwd"] as? String }
            if object["type"] as? String == "custom-title",
               let title = object["customTitle"] as? String, !title.isEmpty { return (title, cwd) }
            guard firstPrompt == nil, object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] else { continue }
            let text: String?
            if let value = content as? String { text = value }
            else if let blocks = content as? [[String: Any]] { text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ") }
            else { text = nil }
            if let text, !text.contains("<local-command-caveat>") {
                let cleaned = text
                    .replacingOccurrences(of: "(?s)<ide_[^>]+>.*?</ide_[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "(?s)<system-reminder>.*?</system-reminder>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "(?s)<command-name>.*?</command-name>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "(?s)<command-args>.*?</command-args>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned != "..." { firstPrompt = cleaned }
            }
        }
        guard let prompt = firstPrompt else { return (nil, cwd) }
        let title = prompt.count > 62 ? String(prompt.prefix(59)) + "…" : prompt
        return (title, cwd)
    }

    nonisolated private static func writeWidgetSnapshot(totals: UsageTotals, sessions: [SessionRow]) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ccusage-widget", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = WidgetUsageSnapshot(
            generatedAt: Date(),
            totals: totals,
            sessions: sessions.map {
                WidgetSessionSnapshot(
                    sessionId: $0.period,
                    projectPath: $0.projectPath,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    totalTokens: $0.totalTokens,
                    totalCost: $0.totalCost,
                    lastActivity: $0.metadata?.lastActivity ?? ""
                )
            }
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory.appendingPathComponent("widget.json"), options: .atomic)
    }

    nonisolated private static func shouldReloadWidget(sessionIDs: [String]) -> Bool {
        let defaults = UserDefaults.standard
        let previousIDs = Set(defaults.stringArray(forKey: "lastReloadedSessionIDs") ?? [])
        let currentIDs = Set(sessionIDs)
        let lastReload = defaults.object(forKey: "lastWidgetReloadAt") as? Date ?? .distantPast
        let sessionSetChanged = previousIDs != currentIDs
        let periodicReloadDue = Date().timeIntervalSince(lastReload) >= 60
        guard sessionSetChanged || periodicReloadDue else { return false }
        defaults.set(Array(currentIDs).sorted(), forKey: "lastReloadedSessionIDs")
        defaults.set(Date(), forKey: "lastWidgetReloadAt")
        return true
    }

    nonisolated private static func run(_ command: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ccusage failed"
                    continuation.resume(throwing: NSError(domain: "ccusage", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]))
                }
            } catch { continuation.resume(throwing: error) }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: UsageStore
    @State private var showSessions = false
    @State private var sessionPage = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TODAY'S USAGE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(store.daily.totalTokens.formattedTokens).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("tokens  ·  \(store.daily.totalCost, format: .currency(code: "USD")) estimated")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }.buttonStyle(.plain).help("Refresh now")
            }

            HStack(spacing: 8) {
                Metric(title: "Input", value: store.daily.inputTokens.formattedTokens)
                Metric(title: "Output", value: store.daily.outputTokens.formattedTokens)
                Metric(title: "Cache read", value: store.daily.cacheReadTokens.formattedTokens)
            }

            Picker("View", selection: $showSessions) {
                Text("Overview").tag(false)
                Text("Sessions (\(store.sessions.count))").tag(true)
            }.pickerStyle(.segmented)

            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else if showSessions {
                VStack(spacing: 8) {
                    if store.sessions.isEmpty {
                        Text("No sessions recorded today").font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ForEach(Array(store.sessions.dropFirst(sessionPage * 2).prefix(2))) { session in
                            SessionRowView(session: session)
                        }
                        if sessionPageCount > 1 {
                            HStack(spacing: 9) {
                                Button { sessionPage = max(0, sessionPage - 1) } label: { Image(systemName: "chevron.left") }
                                    .disabled(sessionPage == 0)
                                Text("Page \(sessionPage + 1) of \(sessionPageCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                Button { sessionPage = min(sessionPageCount - 1, sessionPage + 1) } label: { Image(systemName: "chevron.right") }
                                    .disabled(sessionPage >= sessionPageCount - 1)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Updates automatically every minute. Costs are estimated by ccusage using its pricing data.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }

            HStack {
                Text(store.lastUpdated.map { "Updated \($0, style: .time)" } ?? "Loading…").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(18)
        .frame(width: 360)
        .background(.regularMaterial)
        .background(WindowAccessor())
        .onChange(of: store.sessions.count) { _ in sessionPage = min(sessionPage, max(0, sessionPageCount - 1)) }
        .onOpenURL { url in
            guard url.scheme == "ccusage-widget", url.host == "resume",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let sessionID = components.queryItems?.first(where: { $0.name == "session" })?.value else { return }
            let directory = components.queryItems?.first(where: { $0.name == "directory" })?.value
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            hideCompanionWindow()
            SessionLauncher.open(sessionID: sessionID, directory: directory)
            // Opening a custom URL can trigger the app's reopen handling after this
            // callback. Hide once more on the next run-loop turn so only Terminal remains.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hideCompanionWindow()
            }
        }
    }

    private var sessionPageCount: Int { max(1, Int(ceil(Double(store.sessions.count) / 2.0))) }
}

@MainActor
private func hideCompanionWindow() {
    NSApplication.shared.windows.forEach { $0.orderOut(nil) }
    NSApplication.shared.hide(nil)
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        }
    }
}

struct Metric: View {
    let title: String; let value: String
    var body: some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(value).font(.caption.weight(.semibold)) }.frame(maxWidth: .infinity, alignment: .leading) }
}

struct SessionRowView: View {
    let session: SessionRow
    @State private var isHovering = false
    var body: some View {
        Button(action: openSession) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? session.projectName : session.title).font(.caption.weight(.medium)).lineLimit(1)
                    Text("\(session.directoryDisplay) · \(session.lastActivityText)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.totalTokens.formattedTokens).font(.caption.weight(.semibold))
                    Text(session.totalCost, format: .currency(code: "USD")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(isHovering ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Resume this Claude Code session")
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func openSession() {
        let directory = session.workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : session.workingDirectory
        SessionLauncher.open(sessionID: session.period, directory: directory)
    }
}

enum SessionLauncher {
    static func open(sessionID: String, directory: String) {
        let shellDirectory = "'" + directory.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/zsh
        cd \(shellDirectory) || exit 1
        exec /opt/homebrew/bin/claude --resume \(sessionID)
        """
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ccusage-widget/resume", isDirectory: true)
        let file = directoryURL.appendingPathComponent("ccusage-resume-\(sessionID).command")
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
                if error != nil { NSSound.beep() }
            }
        } catch {
            NSSound.beep()
        }
    }
}

extension SessionRow {
    var directoryDisplay: String {
        guard !workingDirectory.isEmpty else { return projectName }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory == home { return "~" }
        if workingDirectory.hasPrefix(home + "/") { return "~" + workingDirectory.dropFirst(home.count) }
        return workingDirectory
    }

    var projectName: String {
        let cleaned = projectPath
            .replacingOccurrences(of: "-Users-HingstM-", with: "")
            .replacingOccurrences(of: "-", with: " ")
        let words = cleaned.split(separator: " ").map(String.init)
        if words.isEmpty { return "Claude session" }
        return words.suffix(4).joined(separator: " / ")
    }

    var lastActivityText: String {
        guard let raw = metadata?.lastActivity else { return "time unavailable" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "time unavailable" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}

extension Int {
    var formattedTokens: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return formatted()
    }
}

@main
struct CCUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(CCUsageAppDelegate.self) private var appDelegate
    var body: some Scene { WindowGroup("ccusage") { ContentView(store: .shared) }.windowStyle(.hiddenTitleBar) }
}

@MainActor
final class CCUsageAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UsageStore.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.forEach { $0.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }
}
