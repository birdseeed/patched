import Foundation

/// Sparkle feeds Patched knows for a few apps that pin a Sparkle EdDSA key but set their feed URL at runtime, so
/// their Info.plist has no `SUFeedURL`. An entry here only says where the feed is: the download must still carry the
/// installed app's Team ID and verify against the app's own `SUPublicEDKey`. The user's `catalogue.json` always wins.
/// Compiled-in constants: nothing is read from disk or the network to build this list.
public enum BuiltInCatalogue {
    public static let feeds: [String: UpdateSource] = [
        // ChatGPT
        "com.openai.codex": .sparkle(feed: URL(string: "https://persistent.oaistatic.com/codex-app-prod/appcast.xml")!),
        // Ghostty
        "com.mitchellh.ghostty": .sparkle(feed: URL(string: "https://release.files.ghostty.org/appcast.xml")!),
    ]
}
