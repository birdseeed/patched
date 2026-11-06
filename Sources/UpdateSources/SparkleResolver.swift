import Foundation

/// Resolves the newest compatible full-update item from a Sparkle appcast.
public enum SparkleResolver {
    static let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

    public static func resolve(feed: URL, fetcher: any HTTPFetching, environment: HostEnvironment, installedBuild: String? = nil, installedShortVersion: String? = nil) async -> Result<UpdateOffer, RefusalReason> {
        guard feed.isHTTPS else { return .failure(.insecureFeed(feed.absoluteString)) }
        let data: Data
        do { data = try await fetcher.fetch(feed, maxBytes: FetchLimits.feedBytes) }
        catch let error as FetchError { return .failure(error.refusal) }
        catch { return .failure(.network(error.localizedDescription)) }
        guard data.count <= FetchLimits.feedBytes else { return .failure(.tooLarge) }
        return parse(data, feed: feed, environment: environment, installedBuild: installedBuild, installedShortVersion: installedShortVersion)
    }

    public static func parse(_ data: Data, feed: URL, environment: HostEnvironment, installedBuild: String? = nil, installedShortVersion: String? = nil) -> Result<UpdateOffer, RefusalReason> {
        guard data.count <= FetchLimits.feedBytes else { return .failure(.tooLarge) }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard !bytes.contains(0), let xml = String(data: bytes, encoding: .utf8) else {
            return .failure(.malformedFeed("only UTF-8 XML is supported"))
        }
        if let declaration = xml.range(of: "^<\\?xml[^?]*\\?>", options: .regularExpression) {
            let header = String(xml[declaration])
            if let encoding = header.range(of: "encoding\\s*=\\s*['\"]([^'\"]+)['\"]", options: [.regularExpression, .caseInsensitive]) {
                let field = String(header[encoding])
                if field.range(of: "['\"](?:utf-8|utf8|us-ascii|ascii)['\"]", options: [.regularExpression, .caseInsensitive]) == nil {
                    return .failure(.malformedFeed("only UTF-8 XML is supported"))
                }
            }
        }
        if xml.contains("<!ENTITY") { return .failure(.malformedFeed("entity declarations are not allowed")) }
        let collector = AppcastCollector()
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false   // XXE must stay impossible.
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = collector
        let parsed = parser.parse()
        // The parser must never ask us for an external entity; if it does, something enabled resolution.
        guard !collector.sawExternalEntityRequest else { return .failure(.malformedFeed("external entity references are not supported")) }
        guard parsed, !collector.rejected, collector.rootName != nil else {
            return .failure(.malformedFeed(parser.parserError?.localizedDescription ?? "not XML"))
        }
        guard collector.rootName == "rss" else { return .failure(.malformedFeed("root element is not <rss>")) }

        var best: (version: String, offer: UpdateOffer)?
        var insecure: String?
        for item in collector.items {
            guard let enclosure = item.enclosure else { continue }
            if item.channel != nil { continue }
            if let os = item.os, os.lowercased() != "macos" { continue }
            if let hw = item.hardwareRequirements, hw.lowercased().contains("arm64"), environment.arch != .arm64 { continue }
            if let minimum = item.minimumSystemVersion,
               VersionComparator.compare(environment.osVersion, minimum) == .orderedAscending { continue }
            if let maximum = item.maximumSystemVersion,
               VersionComparator.compare(environment.osVersion, maximum) == .orderedDescending { continue }
            if let required = item.minimumUpdateVersion {
                guard let installed = installedBuild ?? installedShortVersion,
                      VersionComparator.compare(installed, required) != .orderedAscending else { continue }
            }
            let build = item.version, short = item.shortVersion
            guard let comparable = build ?? short else { continue }
            guard let urlString = enclosure.url, let url = URL(string: urlString, relativeTo: feed)?.absoluteURL else { continue }
            guard url.isHTTPS else { insecure = urlString; continue }
            let offer = UpdateOffer(
                displayVersion: short ?? comparable, buildVersion: build, downloadURL: url,
                edSignature: item.edSignature, length: enclosure.length.flatMap { Int($0) },
                minimumSystemVersion: item.minimumSystemVersion,
                format: ArtifactFormat.infer(from: url, mimeType: enclosure.type), source: .sparkle(feed: feed))
            if let current = best, VersionComparator.compare(comparable, current.version) != .orderedDescending { continue }
            best = (comparable, offer)
        }
        if let best { return .success(best.offer) }
        if let insecure { return .failure(.insecureDownload(insecure)) }
        return .failure(.noCompatibleItem)
    }
}

private struct AppcastItem {
    struct Enclosure { var url, length, type: String? }
    var enclosure: Enclosure?
    var minimumUpdateVersion: String?
    var version, shortVersion, edSignature, minimumSystemVersion, maximumSystemVersion, channel, os, hardwareRequirements: String?
}

private final class AppcastCollector: NSObject, XMLParserDelegate {
    var items: [AppcastItem] = []
    var rootName: String?
    var sawExternalEntityRequest = false
    var rejected = false
    private var retained = 0
    private func reject(_ parser: XMLParser) { rejected = true; parser.abortParsing() }
    private func byteCount(_ item: AppcastItem) -> Int {
        [item.enclosure?.url, item.enclosure?.length, item.enclosure?.type, item.version,
         item.shortVersion, item.edSignature, item.minimumSystemVersion, item.maximumSystemVersion,
         item.minimumUpdateVersion, item.channel, item.os, item.hardwareRequirements]
            .compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
    }
    private func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 4096 else { return nil }
        return trimmed
    }
    private func limitCurrent() {
        // An item must keep all captured eligibility constraints together. Rolling back just
        // the last field could make an incompatible release appear eligible.
        if let current, retained + byteCount(current) > 1_048_576 {
            self.current = nil
            capturing = nil
            text = ""
        }
    }
    private var current: AppcastItem?
    private var deltaDepth = 0
    private var capturing: String?
    private var text = ""
    private static let captured: Set<String> = ["version", "shortVersionString", "edSignature", "minimumSystemVersion",
                                                "minimumUpdateVersion", "maximumSystemVersion", "channel", "os", "hardwareRequirements"]

    private func isSparkle(_ namespace: String?, _ qName: String?, _ name: String) -> Bool {
        if let namespace, !namespace.isEmpty { return namespace == SparkleResolver.namespace }
        return (qName ?? name).hasPrefix("sparkle:")
    }
    private func local(_ name: String) -> String { String(name.split(separator: ":").last ?? Substring(name)) }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = local(elementName)
        if rootName == nil { rootName = name }
        let sparkle = isSparkle(namespaceURI, qName, elementName)
        if !sparkle {
            if name == "item" {
                current = items.count < 2000 ? AppcastItem() : nil
                deltaDepth = 0
            }
            else if name == "enclosure", current != nil, deltaDepth == 0, current?.enclosure == nil {
                var attrs: [String: String] = [:]
                var delta = false
                let wanted: Set<String> = ["url", "length", "type", "version", "shortVersionString", "edSignature", "os", "minimumSystemVersion"]
                for (key, value) in attributeDict {
                    let key = local(key)
                    if key == "deltaFrom" { delta = true }
                    if wanted.contains(key) { attrs[key] = bounded(value) }
                }
                if !delta {
                    current?.enclosure = .init(url: attrs["url"], length: attrs["length"], type: attrs["type"])
                    if let v = attrs["version"] { current?.version = v }
                    if let v = attrs["shortVersionString"] { current?.shortVersion = v }
                    if let v = attrs["edSignature"] { current?.edSignature = v }
                    if let v = attrs["os"] { current?.os = v }
                    if let v = attrs["minimumSystemVersion"] { current?.minimumSystemVersion = v }
                    limitCurrent()
                }
            }
        } else if current != nil {
            if name == "deltas" { deltaDepth += 1 }
            else if deltaDepth == 0, Self.captured.contains(name) { capturing = name; text = "" }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        if isSparkle(namespaceURI, qName, elementName) {
            if name == "deltas", deltaDepth > 0 { deltaDepth -= 1 }
            if capturing == name {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                capturing = nil
                if !value.isEmpty { assign(name, value) }
            }
        } else if name == "item", let item = current {
            if item.enclosure != nil { items.append(item); retained += byteCount(item) }
            current = nil; capturing = nil; text = ""
        }
    }

    // Element-form values apply only when the enclosure attribute form did not supply them.
    private func assign(_ name: String, _ value: String) {
        guard var item = current else { return }
        switch name {
        case "version": item.version = item.version ?? value
        case "shortVersionString": item.shortVersion = item.shortVersion ?? value
        case "edSignature": item.edSignature = item.edSignature ?? value
        case "minimumSystemVersion": item.minimumSystemVersion = item.minimumSystemVersion ?? value
        case "minimumUpdateVersion": item.minimumUpdateVersion = value
        case "maximumSystemVersion": item.maximumSystemVersion = value
        case "channel": item.channel = value
        case "os": item.os = item.os ?? value
        case "hardwareRequirements": item.hardwareRequirements = value
        default: break
        }
        current = item
        limitCurrent()
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        sawExternalEntityRequest = true
        return nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing != nil else { return }
        guard text.utf8.count + string.utf8.count <= 4096 else {
            capturing = nil; text = ""; return
        }
        text += string
    }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard capturing != nil else { return }
        guard let string = String(data: block, encoding: .utf8) else { reject(parser); return }
        self.parser(parser, foundCharacters: string)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { reject(parser) }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String, type: String?, defaultValue: String?) { reject(parser) }
}
