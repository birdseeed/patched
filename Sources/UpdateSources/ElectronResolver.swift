import Foundation

/// Minimal line-based reader for the flat YAML that electron-builder writes
/// (`app-update.yml`, `latest-mac.yml`). It is not a general YAML parser.
struct MiniYAML {
    var scalars: [String: String] = [:]
    var files: [[String: String]] = []

    init(_ text: String) {
        var inFiles = false
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            let indented = line.first == " " || line.first == "\t"
            if !indented {
                inFiles = false
                guard let (key, value) = Self.pair(trimmed) else { continue }
                if key == "files", value.isEmpty { inFiles = true } else if !value.isEmpty { scalars[key] = value }
            } else if inFiles {
                var body = trimmed
                if body.hasPrefix("- ") || body == "-" {
                    files.append([:]); body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                if !files.isEmpty, let (key, value) = Self.pair(body) { files[files.count - 1][key] = value }
            }
        }
    }

    static func pair(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let first = value.first, first == "\"" || first == "'" {
            if let close = value.dropFirst().firstIndex(of: first) { value = String(value[value.index(after: value.startIndex)..<close]) }
        } else if let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (key, value)
    }
}

public enum ElectronResolver {
    /// Derives the `latest-mac.yml` URL from a bundled `app-update.yml`. `nil` means the provider is unsupported.
    public static func feedURL(fromAppUpdateYML data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let yaml = MiniYAML(text)
        if yaml.scalars["private"]?.lowercased() == "true" { return nil }
        let channel = yaml.scalars["channel"].flatMap { $0.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? $0 : nil } ?? "latest"
        let file = "\(channel)-mac.yml"
        switch yaml.scalars["provider"]?.lowercased() {
        case "generic":
            guard let raw = yaml.scalars["url"], var base = URLComponents(string: raw) else { return nil }
            if !base.percentEncodedPath.hasSuffix("/") { base.percentEncodedPath += "/" }
            base.percentEncodedPath += file
            return base.url
        case "github":
            if let host = yaml.scalars["host"], host.lowercased() != "github.com" { return nil }
            let safe = "^[A-Za-z0-9_.-]+$"
            guard let owner = yaml.scalars["owner"], let repo = yaml.scalars["repo"],
                  owner.range(of: safe, options: .regularExpression) != nil,
                  repo.range(of: safe, options: .regularExpression) != nil else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(file)")
        default:
            return nil
        }
    }

    public static func resolve(feed: URL, fetcher: any HTTPFetching, environment: HostEnvironment) async -> Result<UpdateOffer, RefusalReason> {
        guard feed.isHTTPS else { return .failure(.insecureFeed(feed.absoluteString)) }
        let data: Data
        do { data = try await fetcher.fetch(feed, maxBytes: FetchLimits.feedBytes) }
        catch let error as FetchError { return .failure(error.refusal) }
        catch { return .failure(.network(error.localizedDescription)) }
        guard data.count <= FetchLimits.feedBytes else { return .failure(.tooLarge) }
        return parse(data, feed: feed, environment: environment)
    }

    public static func parse(_ data: Data, feed: URL, environment: HostEnvironment) -> Result<UpdateOffer, RefusalReason> {
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.malformedFeed("not UTF-8")) }
        let yaml = MiniYAML(text)
        guard let version = yaml.scalars["version"], !version.isEmpty else { return .failure(.malformedFeed("no version")) }

        let minimum = yaml.scalars["minimumSystemVersion"]
        if let minimum, VersionComparator.compare(environment.kernelVersion, minimum) == .orderedAscending {
            return .failure(.noCompatibleItem)
        }
        var entries = yaml.files
        if entries.isEmpty, let path = yaml.scalars["path"] {
            var legacy = ["url": path]
            legacy["sha512"] = yaml.scalars["sha512"]
            entries = [legacy]
        }
        struct Candidate { let score: Int; let url: URL; let sha512: String?; let size: Int?; let format: ArtifactFormat }
        var best: Candidate?
        var insecure: String?
        for entry in entries {
            guard let raw = entry["url"], !raw.isEmpty, let url = resolve(raw, against: feed) else { continue }
            let format = ArtifactFormat.infer(from: url)
            guard format == .zip || format == .dmg else { continue }
            guard url.isHTTPS else { insecure = raw; continue }
            // Inspect only the artifact's declared path, not inherited feed directories, host or query.
            let path = URL(string: raw)?.path.lowercased() ?? ""
            func token(_ names: String) -> Bool {
                path.range(of: "(?:^|[/_. -])(?:" + names + ")(?:$|[/_. -])", options: .regularExpression) != nil
            }
            let isArm = token("arm64|aarch64")
            let isIntel = token("x64|x86_64|intel")
            let isUniversal = token("universal")
            var score: Int
            switch environment.arch {
            case .arm64:
                if isArm || isUniversal { score = 0 } else if isIntel { continue } else { score = 100 }  // unmarked = x64 by electron-builder convention
            case .x86_64:
                if isArm { continue } else { score = 0 }
            }
            if format == .dmg { score += 1 }
            let candidate = Candidate(score: score, url: url, sha512: entry["sha512"], size: entry["size"].flatMap { Int($0) }, format: format)
            if best == nil || candidate.score < best!.score { best = candidate }
        }
        guard let best else {
            if let insecure { return .failure(.insecureDownload(insecure)) }
            return .failure(.noCompatibleItem)
        }
        return .success(UpdateOffer(displayVersion: version, downloadURL: best.url, sha512: best.sha512, length: best.size,
                                    minimumKernelVersion: minimum, format: best.format, source: .electron(feed: feed)))
    }

    static func resolve(_ raw: String, against base: URL) -> URL? {
        guard let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
              var result = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
        let sameOrigin = resolved.scheme?.lowercased() == base.scheme?.lowercased()
            && resolved.host?.lowercased() == base.host?.lowercased()
            && (resolved.port ?? 443) == (base.port ?? 443)
        if sameOrigin, let query = URLComponents(url: base, resolvingAgainstBaseURL: false)?.percentEncodedQuery, !query.isEmpty {
            result.percentEncodedQuery = query
        }
        return result.url
    }
}
