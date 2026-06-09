//
//  OpenClickyForegroundContextTitleProvider.swift
//  OpenClicky
//
//  Derives a useful foreground context label for the notch. Prefer the active
//  project/document title when the focused app exposes one; fall back to the
//  application name when it does not.
//

import ApplicationServices
import AppKit
import Foundation

nonisolated enum OpenClickyForegroundContextTitleProvider {
    static func displayTitle(for app: NSRunningApplication, fallbackName: String) -> String {
        let fallback = normalizedFallbackName(fallbackName)
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return fallback
        }

        for windowTitle in windowTitleCandidates(for: app, fallbackName: fallback) {
            if let contextualTitle = projectTitle(
                from: windowTitle,
                appName: fallback,
                bundleIdentifier: app.bundleIdentifier
            ) {
                return contextualTitle
            }
        }

        return fallback
    }

    static func primaryWindowTitle(for app: NSRunningApplication, fallbackName: String) -> String? {
        windowTitleCandidates(for: app, fallbackName: normalizedFallbackName(fallbackName)).first
    }

    private static func windowTitleCandidates(for app: NSRunningApplication, fallbackName: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ candidate: String?) {
            guard let candidate else { return }
            let cleaned = compactWhitespace(candidate)
            guard !cleaned.isEmpty,
                  !sameTitle(cleaned, fallbackName),
                  seen.insert(cleaned.lowercased()).inserted else {
                return
            }
            candidates.append(cleaned)
        }

        append(scriptedProjectTitle(for: app))
        append(systemEventsWindowTitle(for: app))
        append(focusedWindowTitle(for: app))
        screenRecordingWindowTitles(for: app).forEach { append($0) }
        return candidates
    }

    private static func scriptedProjectTitle(for app: NSRunningApplication) -> String? {
        switch app.bundleIdentifier?.lowercased() {
        case "com.apple.dt.xcode":
            guard hasAutomationPermission(for: "com.apple.dt.Xcode") else { return nil }
            return executeAppleScript("""
            tell application id "com.apple.dt.Xcode"
                try
                    return path of active workspace document
                on error
                    try
                        return name of active workspace document
                    on error
                        return ""
                    end try
                end try
            end tell
            """)
        default:
            return nil
        }
    }

    private static func executeAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error),
              let value = descriptor.stringValue else {
            return nil
        }
        let cleaned = compactWhitespace(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func hasAutomationPermission(for bundleIdentifier: String) -> Bool {
        OpenClickyForegroundAutomationPermissionMemo.shared.hasPermission(for: bundleIdentifier)
    }

    private static func systemEventsWindowTitle(for app: NSRunningApplication) -> String? {
        guard hasAutomationPermission(for: OpenClickyMacPrivacyPermissionProbe.systemEventsBundleIdentifier) else {
            return nil
        }

        let pid = app.processIdentifier
        return executeAppleScript("""
        tell application "System Events"
            try
                set targetProcesses to application processes whose unix id is \(pid)
                if (count of targetProcesses) is 0 then return ""
                tell item 1 of targetProcesses
                    if (count of windows) is 0 then return ""
                    return name of front window
                end tell
            on error
                return ""
            end try
        end tell
        """)
    }

    private static func focusedWindowTitle(for app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(
                appElement,
                attribute as CFString,
                &windowValue
            )
            guard windowResult == .success,
                  let windowValue,
                  CFGetTypeID(windowValue) == AXUIElementGetTypeID() else {
                continue
            }

            var titleValue: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(
                windowValue as! AXUIElement,
                kAXTitleAttribute as CFString,
                &titleValue
            )
            guard titleResult == .success,
                  let title = titleValue as? String else {
                continue
            }

            let cleaned = compactWhitespace(title)
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return nil
    }

    private static func screenRecordingWindowTitles(for app: NSRunningApplication) -> [String] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let name = info[kCGWindowName as String] as? String else {
                return nil
            }
            return compactWhitespace(name)
        }
        .filter { !$0.isEmpty }
    }

    private static func projectTitle(
        from windowTitle: String,
        appName: String,
        bundleIdentifier: String?
    ) -> String? {
        let cleanedTitle = displayNameComponent(from: compactWhitespace(windowTitle))
        guard !cleanedTitle.isEmpty,
              !sameTitle(cleanedTitle, appName) else {
            return nil
        }

        let normalizedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        let appNames = appNameAliases(appName: appName, bundleIdentifier: normalizedBundleIdentifier)
        let strippedTitle = stripTrailingAppName(from: cleanedTitle, appNames: appNames)
        let parts = splitWindowTitle(strippedTitle)
            .map { stripProjectFileSuffix(stripDecorativeState(from: $0)) }
            .filter { part in
                !part.isEmpty && !appNames.contains { sameTitle(part, $0) }
            }

        if normalizedBundleIdentifier == "com.apple.dt.xcode" {
            return bestXcodeProjectTitle(parts: parts, fullTitle: strippedTitle, appName: appName)
        }

        if isCodeEditorBundleIdentifier(normalizedBundleIdentifier) {
            return bestCodeEditorProjectTitle(parts: parts, fullTitle: strippedTitle, appName: appName)
        }

        if parts.count == 1 {
            return meaningfulTitle(parts[0], fallbackAppName: appName)
        }

        if let nonFile = parts.last(where: { !looksLikeFileTitle($0) }),
           let title = meaningfulTitle(nonFile, fallbackAppName: appName) {
            return title
        }

        return meaningfulTitle(strippedTitle, fallbackAppName: appName)
    }

    private static func bestXcodeProjectTitle(parts: [String], fullTitle: String, appName: String) -> String? {
        if let projectPart = parts.first(where: {
            $0.localizedCaseInsensitiveContains(".xcodeproj")
                || $0.localizedCaseInsensitiveContains(".xcworkspace")
        }) {
            return meaningfulTitle(stripProjectFileSuffix(projectPart), fallbackAppName: appName)
        }

        if let first = parts.first,
           let title = meaningfulTitle(first, fallbackAppName: appName) {
            return title
        }

        return meaningfulTitle(stripProjectFileSuffix(fullTitle), fallbackAppName: appName)
    }

    private static func bestCodeEditorProjectTitle(parts: [String], fullTitle: String, appName: String) -> String? {
        let nonFileParts = parts.filter { !looksLikeFileTitle($0) }
        if let last = nonFileParts.last,
           let title = meaningfulTitle(last, fallbackAppName: appName) {
            return title
        }

        if let last = parts.last,
           let title = meaningfulTitle(last, fallbackAppName: appName) {
            return title
        }

        return meaningfulTitle(fullTitle, fallbackAppName: appName)
    }

    private static func splitWindowTitle(_ title: String) -> [String] {
        var normalized = title
        for separator in [" — ", " – ", " | ", " • ", " - "] {
            normalized = normalized.replacingOccurrences(of: separator, with: titleSeparatorToken)
        }

        return normalized
            .components(separatedBy: titleSeparatorToken)
            .map(compactWhitespace)
            .filter { !$0.isEmpty }
    }

    private static func stripTrailingAppName(from title: String, appNames: [String]) -> String {
        var result = title
        let separators = [" — ", " – ", " - ", " | ", " • "]
        var changed = true

        while changed {
            changed = false
            for separator in separators {
                for appName in appNames where sameTitleSuffix(result, suffix: "\(separator)\(appName)") {
                    result = String(result.dropLast(separator.count + appName.count))
                    result = compactWhitespace(result)
                    changed = true
                }
            }
        }

        return result
    }

    private static func stripDecorativeState(from value: String) -> String {
        var result = value
        for prefix in ["● ", "• "] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        return compactWhitespace(result)
    }

    private static func stripProjectFileSuffix(_ value: String) -> String {
        var result = displayNameComponent(from: value)
        for suffix in [".xcodeproj", ".xcworkspace", ".playground"] where result.localizedCaseInsensitiveContains(suffix) {
            if let range = result.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                result.removeSubrange(range)
            }
        }
        return compactWhitespace(result)
    }

    private static func displayNameComponent(from value: String) -> String {
        let cleaned = compactWhitespace(value)
        guard cleaned.contains("/") || cleaned.contains("\\") else { return cleaned }
        let normalizedPath = cleaned.replacingOccurrences(of: "\\", with: "/")
        let component = normalizedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        return compactWhitespace(component ?? cleaned)
    }

    private static func meaningfulTitle(_ title: String, fallbackAppName: String) -> String? {
        let cleaned = compactWhitespace(title)
        guard cleaned.count >= 2,
              !sameTitle(cleaned, fallbackAppName) else {
            return nil
        }
        return String(cleaned.prefix(80))
    }

    private static func looksLikeFileTitle(_ value: String) -> Bool {
        let trimmed = compactWhitespace(value)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed.contains("\\") {
            return true
        }

        let lastComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        guard let dotRange = lastComponent.range(of: ".", options: .backwards),
              dotRange.lowerBound != lastComponent.startIndex else {
            return false
        }

        let ext = String(lastComponent[dotRange.upperBound...]).lowercased()
        guard !ext.isEmpty, ext.count <= 12 else { return false }
        return !["xcodeproj", "xcworkspace", "playground"].contains(ext)
    }

    private static func appNameAliases(appName: String, bundleIdentifier: String) -> [String] {
        var names = Set([appName])
        switch bundleIdentifier {
        case "com.microsoft.vscode":
            names.formUnion(["Code", "Visual Studio Code"])
        case "com.todesktop.230313mzl4w4u92", "com.cursor.cursor":
            names.insert("Cursor")
        case "dev.zed.zed":
            names.insert("Zed")
        case "com.apple.dt.xcode":
            names.insert("Xcode")
        default:
            break
        }
        return names.map(compactWhitespace).filter { !$0.isEmpty }
    }

    private static func isCodeEditorBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.microsoft.vscode"
            || bundleIdentifier == "com.todesktop.230313mzl4w4u92"
            || bundleIdentifier == "com.cursor.cursor"
            || bundleIdentifier == "dev.zed.zed"
            || bundleIdentifier.contains("windsurf")
    }

    private static func normalizedFallbackName(_ value: String) -> String {
        let cleaned = compactWhitespace(value)
        return cleaned.isEmpty ? "Current app" : cleaned
    }

    private static func compactWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        compactWhitespace(lhs).caseInsensitiveCompare(compactWhitespace(rhs)) == .orderedSame
    }

    private static func sameTitleSuffix(_ value: String, suffix: String) -> Bool {
        compactWhitespace(value).lowercased().hasSuffix(compactWhitespace(suffix).lowercased())
    }

    private static let titleSeparatorToken = "\u{1f}"
}

private final class OpenClickyForegroundAutomationPermissionMemo {
    static let shared = OpenClickyForegroundAutomationPermissionMemo()

    private let lock = NSLock()
    private var cache: [String: (allowed: Bool, checkedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 300

    func hasPermission(for bundleIdentifier: String) -> Bool {
        let now = Date()
        lock.lock()
        if let cached = cache[bundleIdentifier],
           now.timeIntervalSince(cached.checkedAt) < cacheTTL {
            lock.unlock()
            return cached.allowed
        }
        lock.unlock()

        let allowed = OpenClickyMacPrivacyPermissionProbe.hasAppleEventsAutomationPermission(
            targetBundleIdentifier: bundleIdentifier,
            prompt: false
        )

        lock.lock()
        cache[bundleIdentifier] = (allowed, now)
        lock.unlock()
        return allowed
    }
}
