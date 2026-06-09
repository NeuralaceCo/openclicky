//
//  OpenClickyForegroundIntentProvider.swift
//  OpenClicky
//
//  Infers a glanceable intent label and a short intent brief from the current
//  foreground state plus rolling foreground state history.
//

import Foundation

nonisolated struct OpenClickyForegroundIntentState: Sendable, Equatable {
    let capturedAt: Date
    let bundleIdentifier: String?
    let appName: String
    let contextTitle: String
    let rawWindowTitle: String?
    let browserURLString: String?
    let isBrowser: Bool
}

nonisolated struct OpenClickyForegroundIntentInsight: Sendable, Equatable {
    let headline: String
    let detailLines: [String]

    var displayLines: [String] {
        Array(([headline] + detailLines).prefix(4))
    }

    var displayText: String {
        displayLines.joined(separator: "\n")
    }
}

actor OpenClickyForegroundIntentProvider {
    private var history: [OpenClickyForegroundIntentState] = []
    private var recentFrames: [OpenClickyForegroundIntentState] = []
    private let retentionWindow: TimeInterval = 180
    private let maximumHistoryCount = 90
    private let frameRetentionWindow: TimeInterval = 5
    private let maximumFrameHistoryCount = 16

    func intentLabel(for state: OpenClickyForegroundIntentState) -> String? {
        intentInsight(for: state)?.displayText
    }

    func intentInsight(for state: OpenClickyForegroundIntentState) -> OpenClickyForegroundIntentInsight? {
        append(state)
        let headline = inferIntent(for: state) ?? fallbackIntent(for: state)
        return OpenClickyForegroundIntentInsight(
            headline: headline,
            detailLines: [
                focusLine(for: state),
                recentLine(for: state),
                nextLine(for: state, headline: headline)
            ]
        )
    }

    private func append(_ state: OpenClickyForegroundIntentState) {
        recentFrames.append(state)
        pruneRecentFrames(relativeTo: state.capturedAt)

        let last = history.last
        if last?.signature == state.signature {
            history[history.count - 1] = state
        } else {
            history.append(state)
        }

        let cutoff = state.capturedAt.addingTimeInterval(-retentionWindow)
        history.removeAll { $0.capturedAt < cutoff }
        if history.count > maximumHistoryCount {
            history.removeFirst(history.count - maximumHistoryCount)
        }
    }

    private func pruneRecentFrames(relativeTo date: Date) {
        let cutoff = date.addingTimeInterval(-frameRetentionWindow)
        recentFrames.removeAll { $0.capturedAt < cutoff }
        if recentFrames.count > maximumFrameHistoryCount {
            recentFrames.removeFirst(recentFrames.count - maximumFrameHistoryCount)
        }
    }

    private func inferIntent(for state: OpenClickyForegroundIntentState) -> String? {
        let recent = history.suffix(12)
        let recentAppSwitches = zip(recent, recent.dropFirst()).filter { first, second in
            first.normalizedBundleIdentifier != second.normalizedBundleIdentifier
        }.count
        if recentAppSwitches >= 4 {
            return "Switching context"
        }

        if state.isBrowser {
            return browserIntent(for: state)
        }

        let bundle = state.normalizedBundleIdentifier
        if isCodeEditor(bundle) {
            return codeEditorIntent(for: state)
        }

        if bundle == "com.apple.dt.xcode" {
            return xcodeIntent(for: state)
        }

        if bundle.contains("terminal") || bundle == "com.googlecode.iterm2" || bundle == "dev.warp.warp-stable" {
            return terminalIntent(for: state)
        }

        if bundle == "com.figma.desktop" {
            return "Designing UI"
        }
        if bundle.contains("linear") {
            return "Planning work"
        }
        if bundle.contains("notion") {
            return "Writing notes"
        }
        if bundle.contains("slack") {
            return "Messaging"
        }
        if bundle.contains("mail") || bundle.contains("outlook") {
            return "Handling email"
        }
        if bundle.contains("calendar") {
            return "Checking schedule"
        }

        return genericDocumentIntent(for: state)
    }

    private func browserIntent(for state: OpenClickyForegroundIntentState) -> String {
        guard let urlString = state.browserURLString,
              let url = URL(string: urlString) else {
            return "Browsing"
        }

        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        let title = state.contextTitle.lowercased()
        let path = url.path.lowercased()

        if host.contains("github.com") {
            if path.contains("/pull/") || title.contains("pull request") { return "Reviewing PR" }
            if path.contains("/issues/") || title.contains("issue") { return "Reviewing issue" }
            return "Reviewing GitHub"
        }
        if host.contains("docs.") || host.contains("developer.") || path.contains("/docs") || title.contains("documentation") {
            return "Reading docs"
        }
        if host.contains("google.") || host.contains("kagi.com") || host.contains("bing.com") || host.contains("duckduckgo.com") {
            return "Searching web"
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return "Watching video"
        }
        if host.contains("x.com") || host.contains("twitter.com") || host.contains("reddit.com") || host.contains("news.ycombinator.com") {
            return "Reading thread"
        }
        if title.contains("checkout") || title.contains("cart") || title.contains("pricing") {
            return "Shopping"
        }
        return "Reading page"
    }

    private func codeEditorIntent(for state: OpenClickyForegroundIntentState) -> String {
        let rawTitle = state.rawWindowTitle ?? state.contextTitle
        if let language = languageName(from: rawTitle) {
            return "Editing \(language)"
        }

        if recentTitleChanges(inSameAppAs: state) >= 3 {
            return "Navigating files"
        }

        return "Coding"
    }

    private func xcodeIntent(for state: OpenClickyForegroundIntentState) -> String {
        let rawTitle = state.rawWindowTitle ?? state.contextTitle
        if rawTitle.localizedCaseInsensitiveContains("Test") {
            return "Checking tests"
        }
        if let language = languageName(from: rawTitle) {
            return "Editing \(language)"
        }
        return "Building app"
    }

    private func terminalIntent(for state: OpenClickyForegroundIntentState) -> String {
        let title = [state.rawWindowTitle, state.contextTitle]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if title.contains("ssh") { return "Remote shell" }
        if title.contains("npm") || title.contains("pnpm") || title.contains("yarn") { return "Running JS tools" }
        if title.contains("swift") || title.contains("xcodebuild") { return "Building Swift" }
        if title.contains("git") { return "Using Git" }
        return "Using terminal"
    }

    private func genericDocumentIntent(for state: OpenClickyForegroundIntentState) -> String? {
        let rawTitle = state.rawWindowTitle ?? state.contextTitle
        if rawTitle.contains(".pdf") { return "Reading PDF" }
        if rawTitle.contains(".doc") || rawTitle.contains(".pages") { return "Writing document" }
        if rawTitle.contains(".xls") || rawTitle.contains(".numbers") { return "Working spreadsheet" }
        if rawTitle.contains(".ppt") || rawTitle.contains(".key") { return "Editing slides" }
        return nil
    }

    private func fallbackIntent(for state: OpenClickyForegroundIntentState) -> String {
        if state.isBrowser {
            return "Reading page"
        }

        let title = (state.rawWindowTitle ?? state.contextTitle).lowercased()
        if title.contains("settings") || title.contains("preferences") {
            return "Changing settings"
        }
        if !state.contextTitle.isSamePlaceholder(as: state.appName) {
            return "Working on \(state.contextTitle.intentShortened(maxLength: 34))"
        }

        return "Working in \(state.appName.intentShortened(maxLength: 34))"
    }

    private func focusLine(for state: OpenClickyForegroundIntentState) -> String {
        let title = state.contextTitle.intentSingleLine.intentShortened(maxLength: 72)
        if state.isBrowser,
           let urlString = state.browserURLString,
           let url = URL(string: urlString),
           let host = url.host(percentEncoded: false)?.intentReadableHost,
           !host.isEmpty {
            return "Focus: \(title) on \(host)"
        }

        if !state.contextTitle.isSamePlaceholder(as: state.appName) {
            return "Focus: \(title)"
        }

        return "Focus: \(state.appName.intentSingleLine.intentShortened(maxLength: 72))"
    }

    private func recentLine(for state: OpenClickyForegroundIntentState) -> String {
        let frames = recentFrames
        guard let first = frames.first else {
            return "Recent: first foreground sample"
        }

        let elapsed = max(0, state.capturedAt.timeIntervalSince(first.capturedAt))
        let duration = Self.durationLabel(elapsed)
        let appFlow = Self.adjacentDistinctValues(frames.map { $0.appName.intentSingleLine })
        if appFlow.count >= 2 {
            return "Recent: moved \(Self.flowLabel(appFlow)) over \(duration)"
        }

        let titleFlow = Self.adjacentDistinctValues(frames.map { $0.normalizedTitle })
        if titleFlow.count >= 3 {
            let noun = state.isBrowser ? "tabs/pages" : "windows/files"
            return "Recent: scanning related \(noun) for \(duration)"
        }

        let currentApp = state.appName.intentSingleLine.intentShortened(maxLength: 32)
        return "Recent: steady in \(currentApp) for \(duration)"
    }

    private func nextLine(for state: OpenClickyForegroundIntentState, headline: String) -> String {
        let normalizedHeadline = headline.lowercased()

        if normalizedHeadline.contains("switching context") {
            return "Next: settle on the active task or ask for handoff context"
        }
        if normalizedHeadline.contains("reviewing pr") {
            return "Next: compare diffs, comments, checks, and merge risk"
        }
        if normalizedHeadline.contains("reviewing issue") {
            return "Next: decide the fix, owner, or follow-up question"
        }
        if normalizedHeadline.contains("github") {
            return "Next: inspect repo context and choose the relevant artifact"
        }
        if normalizedHeadline.contains("docs") {
            return "Next: apply the referenced API detail to the task"
        }
        if normalizedHeadline.contains("searching") {
            return "Next: choose a result or tighten the query"
        }
        if normalizedHeadline.contains("video") {
            return "Next: extract the relevant step or timestamp"
        }
        if normalizedHeadline.contains("thread") {
            return "Next: pull out the useful signal from the discussion"
        }
        if normalizedHeadline.contains("shopping") {
            return "Next: compare price, fit, trust, or checkout risk"
        }
        if normalizedHeadline.contains("editing") || normalizedHeadline.contains("coding") {
            return "Next: make the code change and verify it"
        }
        if normalizedHeadline.contains("navigating files") {
            return "Next: locate the right file before editing"
        }
        if normalizedHeadline.contains("checking tests") {
            return "Next: inspect failures or rerun a targeted test"
        }
        if normalizedHeadline.contains("building") {
            return "Next: watch build output and fix the first failure"
        }
        if normalizedHeadline.contains("terminal") || normalizedHeadline.contains("git") || normalizedHeadline.contains("shell") || normalizedHeadline.contains("tools") {
            return "Next: read command output or rerun with changes"
        }
        if normalizedHeadline.contains("designing") {
            return "Next: adjust layout, components, copy, or spacing"
        }
        if normalizedHeadline.contains("planning") {
            return "Next: clarify priority, owner, and next action"
        }
        if normalizedHeadline.contains("notes") || normalizedHeadline.contains("document") {
            return "Next: capture the decision or turn notes into action"
        }
        if normalizedHeadline.contains("messaging") || normalizedHeadline.contains("email") {
            return "Next: draft the response with the needed context"
        }
        if normalizedHeadline.contains("schedule") {
            return "Next: confirm time, conflict, or preparation needed"
        }

        if state.isBrowser {
            return "Next: extract what matters from the current page"
        }

        return "Next: continue the current task or ask for context"
    }

    private func recentTitleChanges(inSameAppAs state: OpenClickyForegroundIntentState) -> Int {
        let matching = history.suffix(10).filter { $0.normalizedBundleIdentifier == state.normalizedBundleIdentifier }
        return zip(matching, matching.dropFirst()).filter { first, second in
            first.normalizedTitle != second.normalizedTitle
        }.count
    }

    private func languageName(from title: String) -> String? {
        let lowercased = title.lowercased()
        let mappings: [(String, String)] = [
            (".swift", "Swift"),
            (".ts", "TypeScript"),
            (".tsx", "React"),
            (".js", "JavaScript"),
            (".jsx", "React"),
            (".py", "Python"),
            (".rs", "Rust"),
            (".go", "Go"),
            (".rb", "Ruby"),
            (".java", "Java"),
            (".kt", "Kotlin"),
            (".md", "Markdown"),
            (".json", "JSON"),
            (".yml", "YAML"),
            (".yaml", "YAML"),
            (".css", "CSS"),
            (".html", "HTML")
        ]
        return mappings.first { lowercased.contains($0.0) }?.1
    }

    private func isCodeEditor(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.microsoft.vscode"
            || bundleIdentifier == "com.todesktop.230313mzl4w4u92"
            || bundleIdentifier == "com.cursor.cursor"
            || bundleIdentifier == "dev.zed.zed"
            || bundleIdentifier.contains("windsurf")
    }

    private static func adjacentDistinctValues(_ values: [String]) -> [String] {
        values.reduce(into: [String]()) { result, value in
            let normalized = value.intentSingleLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            if result.last != normalized {
                result.append(normalized)
            }
        }
    }

    private static func flowLabel(_ values: [String]) -> String {
        let compacted = values.suffix(4).map { $0.intentShortened(maxLength: 22) }
        return compacted.joined(separator: " -> ")
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        return "\(seconds)s"
    }
}

private extension OpenClickyForegroundIntentState {
    var normalizedBundleIdentifier: String {
        bundleIdentifier?.lowercased() ?? ""
    }

    var normalizedTitle: String {
        contextTitle
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var signature: String {
        [
            normalizedBundleIdentifier,
            normalizedTitle,
            rawWindowTitle ?? "",
            browserURLString ?? "",
            isBrowser ? "browser" : "app"
        ].joined(separator: "\u{1f}")
    }
}

private extension String {
    var intentSingleLine: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var intentReadableHost: String {
        let lowercasedHost = lowercased()
        if lowercasedHost.hasPrefix("www.") {
            return String(lowercasedHost.dropFirst(4))
        }
        return lowercasedHost
    }

    func intentShortened(maxLength: Int) -> String {
        let compact = intentSingleLine
        guard compact.count > maxLength, maxLength > 3 else { return compact }
        let endIndex = compact.index(compact.startIndex, offsetBy: maxLength - 3)
        return String(compact[..<endIndex]) + "..."
    }

    func isSamePlaceholder(as appName: String) -> Bool {
        let lhs = intentSingleLine.lowercased()
        let rhs = appName.intentSingleLine.lowercased()
        return lhs.isEmpty || lhs == rhs || lhs == "current app"
    }
}
