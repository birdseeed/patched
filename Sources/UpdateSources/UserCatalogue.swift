import Foundation

public struct CatalogueError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// The user's `catalogue.json`: per-bundle-ID source overrides and ignores. Decoding is strict.
public struct UserCatalogue: Sendable, Equatable {
    public enum Entry: Sendable, Equatable { case source(UpdateSource), ignore }
    public static let maxBytes = 1_048_576
    public static let empty = UserCatalogue(entries: [:])
    public let entries: [String: Entry]

    public init(entries: [String: Entry]) { self.entries = entries }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Patched/Updater/catalogue.json")
    }

    /// Returns `.empty` when the file does not exist.
    public static func load(from explicit: URL? = nil) throws -> UserCatalogue {
        let url: URL
        if let explicit { url = explicit } else {
            do { try RealStateTripwire.check("default catalogue.json") } catch { throw CatalogueError(message: "\(error)") }
            url = defaultURL
        }
        let data: Data
        do { data = try BoundedFile.read(url, maxBytes: maxBytes).data }
        catch let error as POSIXError where error.code == .ENOENT { return .empty }
        catch let error as POSIXError where error.code == .ELOOP {
            throw CatalogueError(message: "catalogue.json must be a regular file, not a symlink")
        }
        catch { throw CatalogueError(message: "\(url.path): unreadable or larger than \(maxBytes) bytes") }
        do { return try decode(data) } catch let error as CatalogueError {
            throw CatalogueError(message: "\(url.path): \(error.message)")
        }
    }

    public static func decode(_ data: Data) throws -> UserCatalogue {
        guard data.count <= maxBytes else { throw CatalogueError(message: "catalogue is larger than \(maxBytes) bytes") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CatalogueError(message: "not a JSON object")
        }
        try reject(unknownKeysIn: root, allowed: ["version", "apps"], where: "top level")
        guard let version = root["version"] as? Int, version == 1 else {
            throw CatalogueError(message: "\"version\" must be 1")
        }
        guard let apps = root["apps"] as? [Any] else { throw CatalogueError(message: "\"apps\" must be an array") }
        var entries: [String: Entry] = [:]
        for (index, raw) in apps.enumerated() {
            let place = "apps[\(index)]"
            guard let app = raw as? [String: Any] else { throw CatalogueError(message: "\(place) must be an object") }
            try reject(unknownKeysIn: app, allowed: ["bundleID", "source", "ignore"], where: place)
            guard let bundleID = app["bundleID"] as? String, !bundleID.isEmpty else {
                throw CatalogueError(message: "\(place): \"bundleID\" must be a non-empty string")
            }
            guard entries[bundleID] == nil else { throw CatalogueError(message: "\(place): duplicate bundleID \(bundleID)") }
            switch (app["source"], app["ignore"]) {
            case (nil, let ignore?):
                guard let flag = ignore as? Bool, flag else { throw CatalogueError(message: "\(place): \"ignore\" must be true") }
                entries[bundleID] = .ignore
            case (let source?, nil):
                entries[bundleID] = .source(try decodeSource(source, place: place))
            default:
                throw CatalogueError(message: "\(place): give exactly one of \"source\" or \"ignore\"")
            }
        }
        return UserCatalogue(entries: entries)
    }

    private static func reject(unknownKeysIn dict: [String: Any], allowed: Set<String>, where place: String) throws {
        let unknown = Set(dict.keys).subtracting(allowed).sorted()
        if !unknown.isEmpty { throw CatalogueError(message: "\(place): unknown key(s) \(unknown.map { "\"\($0)\"" }.joined(separator: ", "))") }
    }

    private static func decodeSource(_ raw: Any, place: String) throws -> UpdateSource {
        guard let source = raw as? [String: Any] else { throw CatalogueError(message: "\(place): \"source\" must be an object") }
        try reject(unknownKeysIn: source, allowed: ["sparkle", "electron", "homebrewCask"], where: "\(place).source")
        guard source.count == 1, let (kind, value) = source.first, let text = value as? String, !text.isEmpty else {
            throw CatalogueError(message: "\(place).source: give exactly one of sparkle, electron, homebrewCask as a string")
        }
        switch kind {
        case "homebrewCask":
            guard HomebrewResolver.isValidToken(text) else { throw CatalogueError(message: "\(place).source: invalid cask token \"\(text)\"") }
            return .homebrewCask(token: text)
        default:
            guard let url = URL(string: text), url.host?.isEmpty == false, url.scheme != nil else {
                throw CatalogueError(message: "\(place).source: \"\(text)\" is not a URL")
            }
            return kind == "sparkle" ? .sparkle(feed: url) : .electron(feed: url)
        }
    }
}
