//
//  OpenClickyBrowserTabContextProvider.swift
//  OpenClicky
//
//  Reads the active tab title/URL from supported frontmost browsers and
//  resolves a direct favicon image for OpenClicky's foreground app surfaces.
//

import AppKit
import Foundation

nonisolated struct OpenClickyBrowserApplication: Sendable, Equatable {
    let bundleIdentifier: String
    let displayName: String
}

nonisolated struct OpenClickyBrowserTabContext: Sendable, Equatable {
    let browser: OpenClickyBrowserApplication
    let pageURLString: String
    let title: String
    let faviconData: Data?
    let faviconURLString: String?

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if let host = URL(string: pageURLString)?.host(percentEncoded: false),
           !host.isEmpty {
            return host
        }

        return browser.displayName
    }

    var signature: String {
        [
            browser.bundleIdentifier,
            pageURLString,
            title,
            faviconURLString ?? "",
            "\(faviconData?.count ?? 0)"
        ].joined(separator: "\u{1f}")
    }
}

actor OpenClickyBrowserTabContextProvider {
    static let shared = OpenClickyBrowserTabContextProvider()

    private struct ActiveTabSnapshot {
        let urlString: String
        let title: String
    }

    private struct CachedFavicon {
        let data: Data
        let sourceURLString: String
        let fetchedAt: Date
    }

    private enum BrowserScriptKind {
        case safari
        case chromium
    }

    private let faviconCacheTTL: TimeInterval = 60 * 60
    private let faviconMissCacheTTL: TimeInterval = 5 * 60
    private let tabResultSeparator = "\u{1f}"
    private var faviconCache: [String: CachedFavicon] = [:]
    private var faviconMissCache: [String: Date] = [:]
    private var automationPermissionCache: [String: (allowed: Bool, checkedAt: Date)] = [:]
    private let automationPermissionCacheTTL: TimeInterval = 300

    nonisolated static func isSupportedBrowser(bundleIdentifier: String?) -> Bool {
        browserScriptKind(for: bundleIdentifier) != nil
    }

    nonisolated static func browserApplication(
        bundleIdentifier: String?,
        displayName: String?
    ) -> OpenClickyBrowserApplication? {
        guard let bundleIdentifier,
              isSupportedBrowser(bundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenClickyBrowserApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: trimmedName?.isEmpty == false ? trimmedName! : "Browser"
        )
    }

    func activeTabContext(for browser: OpenClickyBrowserApplication) async -> OpenClickyBrowserTabContext? {
        guard hasAutomationPermission(for: browser.bundleIdentifier) else { return nil }
        guard let snapshot = readActiveTabSnapshot(for: browser) else { return nil }
        let trimmedURLString = snapshot.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else { return nil }

        let favicon = await favicon(for: trimmedURLString)
        return OpenClickyBrowserTabContext(
            browser: browser,
            pageURLString: trimmedURLString,
            title: snapshot.title,
            faviconData: favicon?.data,
            faviconURLString: favicon?.sourceURLString
        )
    }

    private func readActiveTabSnapshot(for browser: OpenClickyBrowserApplication) -> ActiveTabSnapshot? {
        guard let script = activeTabAppleScript(for: browser.bundleIdentifier) else { return nil }

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let value = descriptor.stringValue,
              !value.isEmpty else {
            return nil
        }

        let parts = value.components(separatedBy: tabResultSeparator)
        guard let url = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }

        let title = parts.dropFirst().joined(separator: tabResultSeparator)
        return ActiveTabSnapshot(urlString: url, title: title)
    }

    private func activeTabAppleScript(for bundleIdentifier: String) -> String? {
        guard let kind = Self.browserScriptKind(for: bundleIdentifier) else { return nil }
        let escapedBundleIdentifier = bundleIdentifier.replacingOccurrences(of: "\"", with: "\\\"")

        switch kind {
        case .safari:
            return """
            tell application id "\(escapedBundleIdentifier)"
                if (count of windows) is 0 then return ""
                set activeTab to current tab of front window
                set activeURL to URL of activeTab
                set activeTitle to name of activeTab
                return activeURL & (ASCII character 31) & activeTitle
            end tell
            """
        case .chromium:
            return """
            tell application id "\(escapedBundleIdentifier)"
                if (count of windows) is 0 then return ""
                set activeTab to active tab of front window
                set activeURL to URL of activeTab
                set activeTitle to title of activeTab
                return activeURL & (ASCII character 31) & activeTitle
            end tell
            """
        }
    }

    nonisolated private static func browserScriptKind(for bundleIdentifier: String?) -> BrowserScriptKind? {
        guard let normalized = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        if normalized == "com.apple.safari" || normalized == "com.apple.safaritechnologypreview" {
            return .safari
        }

        if normalized.hasPrefix("com.google.chrome")
            || normalized.hasPrefix("com.microsoft.edgemac")
            || normalized == "com.brave.browser"
            || normalized == "com.operasoftware.opera"
            || normalized == "com.vivaldi.vivaldi"
            || normalized == "company.thebrowser.browser" {
            return .chromium
        }

        return nil
    }

    private func hasAutomationPermission(for bundleIdentifier: String) -> Bool {
        let now = Date()
        if let cached = automationPermissionCache[bundleIdentifier],
           now.timeIntervalSince(cached.checkedAt) < automationPermissionCacheTTL {
            return cached.allowed
        }

        let allowed = OpenClickyMacPrivacyPermissionProbe.hasAppleEventsAutomationPermission(
            targetBundleIdentifier: bundleIdentifier,
            prompt: false
        )
        automationPermissionCache[bundleIdentifier] = (allowed, now)
        return allowed
    }

    private func favicon(for pageURLString: String) async -> CachedFavicon? {
        guard let pageURL = URL(string: pageURLString),
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else {
            return nil
        }

        let cacheKey = faviconCacheKey(for: pageURL)
        if let cached = faviconCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < faviconCacheTTL {
            return cached
        }
        if let missedAt = faviconMissCache[cacheKey],
           Date().timeIntervalSince(missedAt) < faviconMissCacheTTL {
            return nil
        }

        let candidates = await faviconCandidates(for: pageURL)
        for candidate in candidates {
            guard let imageData = await fetchImageData(from: candidate) else { continue }
            let cached = CachedFavicon(
                data: imageData,
                sourceURLString: candidate.absoluteString,
                fetchedAt: Date()
            )
            faviconCache[cacheKey] = cached
            faviconMissCache.removeValue(forKey: cacheKey)
            return cached
        }

        faviconMissCache[cacheKey] = Date()
        return nil
    }

    private func faviconCacheKey(for pageURL: URL) -> String {
        if let scheme = pageURL.scheme?.lowercased(),
           let host = pageURL.host(percentEncoded: false)?.lowercased() {
            let port = pageURL.port.map { ":\($0)" } ?? ""
            return "\(scheme)://\(host)\(port)"
        }
        return pageURL.absoluteString
    }

    private func faviconCandidates(for pageURL: URL) async -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL?) {
            guard let url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            candidates.append(url)
        }

        for link in await declaredIconLinks(for: pageURL) {
            append(link)
        }

        if let origin = originURL(for: pageURL) {
            append(origin.appendingPathComponent("favicon.ico"))
            append(origin.appendingPathComponent("favicon.png"))
            append(origin.appendingPathComponent("apple-touch-icon.png"))
        }

        return candidates
    }

    private func originURL(for pageURL: URL) -> URL? {
        guard let scheme = pageURL.scheme,
              let host = pageURL.host(percentEncoded: false) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = pageURL.port
        return components.url
    }

    private func declaredIconLinks(for pageURL: URL) async -> [URL] {
        guard let html = await fetchHTML(from: pageURL) else { return [] }

        let pattern = #"<link\b(?=[^>]*\brel\s*=\s*["'][^"']*(?:icon|apple-touch-icon)[^"']*["'])[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else {
                return nil
            }
            let rawHref = String(html[range])
            let decodedHref = decodeBasicHTMLEntities(rawHref)
            return URL(string: decodedHref, relativeTo: pageURL)?.absoluteURL
        }
    }

    private func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count <= 1_500_000 else {
                return nil
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        } catch {
            return nil
        }
    }

    private func fetchImageData(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count > 0,
                  data.count <= 1_000_000 else {
                return nil
            }
            if let mimeType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
               !mimeType.contains("image"),
               !mimeType.contains("octet-stream") {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    private func decodeBasicHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) OpenClicky/1.0"
}
