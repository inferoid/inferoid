import AppKit
import Foundation
import LinkPresentation
import UniformTypeIdentifiers

/// The destination collection is inferred once, when a link is added.  Keeping this
/// separate from the network code makes URL behaviour deterministic and testable.
struct CollectionURLClassification: Equatable, Sendable {
    let kind: CollectionKind
    let format: CollectionBookFormat
    let type: CollectionMediaType
}

struct CollectionLinkMetadata: Equatable, Sendable {
    var title: String
    var creator: String
    var siteName: String
    var year: Int?
    var description: String
    var thumbnailURL: URL?
}

enum CollectionLinkParser {
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil { return url }
        return URL(string: "https://\(trimmed)")
    }

    static func classify(_ url: URL) -> CollectionURLClassification {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path.lowercased()
        if host.hasPrefix("audible.") || host.contains(".audible.") {
            return CollectionURLClassification(kind: .library, format: .audiobook, type: .movie)
        }
        if host.hasPrefix("amazon.") || host.contains(".amazon.") {
            let ebook = path.contains("kindle") || path.contains("/clp/") || (url.query ?? "").lowercased().contains("kc_")
            return CollectionURLClassification(kind: .library, format: ebook ? .ebook : .print, type: .movie)
        }
        if host == "youtube.com" || host == "m.youtube.com" || host == "youtu.be" {
            return CollectionURLClassification(kind: .movies, format: .print, type: .youtube)
        }
        if host == "imdb.com" || host.hasSuffix(".imdb.com") || host == "share.google" || host == "google.com" || host == "www.google.com" {
            return CollectionURLClassification(kind: .movies, format: .print, type: .movie)
        }
        if host == "podcasts.apple.com" || host.hasSuffix(".podcasts.apple.com") ||
            (host == "open.spotify.com" && (path.contains("/episode") || path.contains("/episodes/"))) {
            return CollectionURLClassification(kind: .movies, format: .print, type: .podcast)
        }
        return CollectionURLClassification(kind: .articles, format: .print, type: .movie)
    }

    static func metadata(from html: String, url: URL) -> CollectionLinkMetadata {
        let title = firstValue(for: ["og:title", "twitter:title"], in: html) ?? valueInTag("title", html) ?? fallbackTitle(for: url)
        let description = firstValue(for: ["og:description", "description", "twitter:description"], in: html) ?? ""
        let creator = firstValue(for: ["article:author", "author", "byl", "creator"], in: html) ?? ""
        let site = firstValue(for: ["og:site_name"], in: html) ?? displayHost(url)
        let image = firstValue(for: ["og:image", "twitter:image", "twitter:image:src"], in: html)
            ?? amazonImage(in: html)
        let imageURL = image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        let year = year(in: [title, description, html].joined(separator: " "))
        if let host = url.host?.lowercased(), host.contains("amazon.") || host.contains("audible."), let parsed = amazonTitle(clean(title)) {
            return CollectionLinkMetadata(title: parsed.title, creator: creator.isEmpty ? parsed.author : clean(creator), siteName: url.host?.lowercased().contains("audible.") == true ? "Audible" : "Amazon", year: year,
                                          description: clean(description), thumbnailURL: imageURL)
        }
        return CollectionLinkMetadata(title: clean(title), creator: clean(creator), siteName: clean(site), year: year,
                                      description: clean(description), thumbnailURL: imageURL)
    }

    /// Amazon titles look like "Title: Subtitle: Last, First: 9781234567890: Amazon.com: Books" or, for Kindle,
    /// "Amazon.com: Title eBook : Last, First: Kindle Store". Audible: "Title by First Last | Audiobook | Audible.com".
    static func amazonTitle(_ raw: String) -> (title: String, author: String)? {
        if raw.contains(" | ") {
            let first = raw.components(separatedBy: " | ")[0]
            if let range = first.range(of: " by ", options: .backwards) {
                return (String(first[..<range.lowerBound]), String(first[range.upperBound...]))
            }
            return first.isEmpty ? nil : (first, "")
        }
        let noise: Set<String> = ["books", "kindle store", "audible books & originals", "movies & tv", "prime video"]
        var parts = raw.replacingOccurrences(of: #"\s+:\s+|:\s+"#, with: "\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.contains(where: { $0.lowercased().hasPrefix("amazon.") }) else { return nil }
        parts.removeAll { part in
            let lower = part.lowercased()
            return part.isEmpty || lower.hasPrefix("amazon.") || noise.contains(lower) || part.range(of: #"^[0-9Xx-]{10,17}$"#, options: .regularExpression) != nil
        }
        var author = ""
        if parts.count > 1, let index = parts.lastIndex(where: { $0.range(of: #"^[^,]+, [^,]+$"#, options: .regularExpression) != nil }) {
            let names = parts[index].components(separatedBy: ", ")
            author = "\(names[1]) \(names[0])"
            parts.remove(at: index)
        }
        var title = parts.joined(separator: ": ")
        for suffix in [" eBook", " Kindle Edition", " Audible Audiobook", " Paperback", " Hardcover"] where title.hasSuffix(suffix) { title.removeLast(suffix.count) }
        return title.isEmpty ? nil : (title, author)
    }

    /// "Tt0099685", "QILb1YZjnLH5eN0lq", the site name: a title that is really an id or a host.
    static func looksLikeID(_ title: String, url: URL) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if t.lowercased() == displayHost(url).lowercased() || t.lowercased() == (url.host ?? "").lowercased() { return true }
        if t.range(of: #"^(?i)tt\d{5,}$"#, options: .regularExpression) != nil { return true }
        let last = url.path.split(separator: "/").last.map(String.init) ?? ""
        return !last.isEmpty && t.lowercased() == last.lowercased()
            || (!t.contains(" ") && t.count >= 8 && t.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    /// "Goodfellas (1990) - IMDb" → ("Goodfellas", 1990); strips site suffixes such as " - Google Search".
    static func cleanTitle(_ raw: String) -> (title: String, year: Int?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - IMDb", " | IMDb", " - Google Search", " - Google", " | Rotten Tomatoes", " | Letterboxd", " - YouTube", " | Netflix"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        var year: Int?
        if let range = title.range(of: #"\s*\((?:TV (?:Series|Mini Series|Movie) )?((?:19|20)\d{2})(?:[–-](?:\d{4})?\s*)?\)\s*$"#, options: .regularExpression) {
            let inner = String(title[range])
            year = inner.range(of: #"(19|20)\d{2}"#, options: .regularExpression).map { Int(inner[$0]) ?? 0 }
            title.removeSubrange(range)
        }
        return (title.trimmingCharacters(in: .whitespaces), year)
    }

    static func fallbackTitle(for url: URL) -> String {
        let last = url.path.split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? ""
        let candidate = last.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        return candidate.isEmpty ? displayHost(url) : candidate.capitalized
    }

    private static func displayHost(_ url: URL) -> String {
        let host = url.host ?? "Saved link"
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    private static func firstValue(for names: [String], in html: String) -> String? {
        for name in names {
            let wanted = NSRegularExpression.escapedPattern(for: name)
            let tagPattern = #"<meta\b[^>]*>"#
            guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            for match in tagRegex.matches(in: html, range: range) {
                guard let tagRange = Range(match.range, in: html) else { continue }
                let tag = String(html[tagRange])
                let marker = #"(?:property|name)\s*=\s*[\"']"# + wanted + #"[\"']"#
                guard tag.range(of: marker, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                if let value = attribute("content", in: tag), !value.isEmpty { return decodeEntities(value) }
            }
        }
        return nil
    }

    private static func valueInTag(_ name: String, _ html: String) -> String? {
        let pattern = #"<\#(name)\b[^>]*>(.*?)</\#(name)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return decodeEntities(stripTags(String(html[range])))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b\#(name)\s*=\s*([\"'])(.*?)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[range])
    }

    private static func amazonImage(in html: String) -> String? {
        for attributeName in ["data-old-hires", "data-a-dynamic-image"] {
            guard let value = attribute(attributeName, in: html) else { continue }
            if attributeName == "data-old-hires", !value.isEmpty { return decodeEntities(value) }
            let pattern = #"[\"'](https?://[^\"']+)[\"']"#
            let decoded = decodeEntities(value)
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
                  let range = Range(match.range(at: 1), in: decoded) else { continue }
            return String(decoded[range])
        }
        return nil
    }

    private static func year(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"\b((?:19|20)\d{2})\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func clean(_ value: String) -> String { stripTags(decodeEntities(value)).trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func stripTags(_ value: String) -> String { value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression) }
    static func decodeEntities(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        if let regex = try? NSRegularExpression(pattern: #"&#([xX][0-9a-fA-F]+|[0-9]+);"#) {
            let ns = out as NSString
            var result = ""; var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let body = ns.substring(with: match.range(at: 1))
                let code = body.hasPrefix("x") || body.hasPrefix("X") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let code, let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) } else { result += ns.substring(with: match.range) }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct FetchedCollectionLink: Sendable {
    let url: URL
    let classification: CollectionURLClassification
    let metadata: CollectionLinkMetadata
    let thumbnailData: Data?
    let thumbnailExtension: String
}

enum CollectionLinkFetcher {
    private static let maxBytes = 2 * 1024 * 1024

    static func fetch(_ url: URL) async throws -> FetchedCollectionLink {
        let classification = CollectionLinkParser.classify(url)
        var oEmbed: CollectionLinkMetadata?
        if classification.type == .youtube { oEmbed = try? await fetchYouTubeMetadata(url) }
        var metadata: CollectionLinkMetadata
        do {
            let html = try await fetchText(url)
            let parsed = CollectionLinkParser.metadata(from: html, url: url)
            metadata = merge(oEmbed, parsed, url: url)
        } catch {
            // Blocked or failed page (IMDb answers plain requests with a challenge): the system preview below still works.
            metadata = oEmbed ?? CollectionLinkMetadata(title: "", creator: "", siteName: url.host ?? "", year: nil, description: "", thumbnailURL: nil)
        }
        var thumbnailData: Data?
        var thumbnailExtension = "jpg"
        if let imageURL = metadata.thumbnailURL {
            thumbnailData = try? await fetchData(imageURL)
            thumbnailExtension = imageURL.pathExtension.isEmpty ? "jpg" : imageURL.pathExtension.lowercased()
        }
        // Sites that block plain fetches (IMDb, Google share links) still give Messages its preview: use the same
        // system link preview when the title looks like an id or there is no picture.
        if thumbnailData == nil || CollectionLinkParser.looksLikeID(metadata.title, url: url) {
            if let preview = await SystemLinkPreview.fetch(url) {
                if CollectionLinkParser.looksLikeID(metadata.title, url: url) || metadata.title.isEmpty, let title = preview.title, !title.isEmpty {
                    let cleaned = CollectionLinkParser.cleanTitle(title)
                    metadata.title = cleaned.title
                    if metadata.year == nil { metadata.year = cleaned.year }
                }
                if thumbnailData == nil, let image = preview.image { thumbnailData = image; thumbnailExtension = "png" }
            }
        }
        if metadata.title.isEmpty { metadata.title = CollectionLinkParser.fallbackTitle(for: url) }
        if metadata.year == nil { metadata.year = CollectionLinkParser.cleanTitle(metadata.title).year }
        metadata.title = CollectionLinkParser.cleanTitle(metadata.title).title
        return FetchedCollectionLink(url: url, classification: classification, metadata: metadata,
                                     thumbnailData: thumbnailData, thumbnailExtension: thumbnailExtension)
    }

    private static func merge(_ oEmbed: CollectionLinkMetadata?, _ parsed: CollectionLinkMetadata, url: URL) -> CollectionLinkMetadata {
        guard let oEmbed else { return parsed }
        return CollectionLinkMetadata(title: oEmbed.title.isEmpty ? parsed.title : oEmbed.title,
                                      creator: oEmbed.creator.isEmpty ? parsed.creator : oEmbed.creator,
                                      siteName: parsed.siteName, year: parsed.year, description: parsed.description,
                                      thumbnailURL: oEmbed.thumbnailURL ?? parsed.thumbnailURL)
    }

    private static func fetchYouTubeMetadata(_ url: URL) async throws -> CollectionLinkMetadata {
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        let data = try await fetchData(components.url!)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let title = object?["title"] as? String ?? CollectionLinkParser.fallbackTitle(for: url)
        let creator = object?["author_name"] as? String ?? ""
        let image = (object?["thumbnail_url"] as? String).flatMap(URL.init(string:))
        return CollectionLinkMetadata(title: title, creator: creator, siteName: "YouTube", year: nil, description: "", thumbnailURL: image)
    }

    private static func fetchText(_ url: URL) async throws -> String {
        String(data: try await fetchData(url), encoding: .utf8) ?? ""
    }

    private static func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) { throw URLError(.badServerResponse) }
        var data = Data()
        data.reserveCapacity(maxBytes)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= maxBytes { break }
        }
        return data
    }
}


/// Apple's link preview (what Messages shows when you paste a link): title and picture, even for sites that refuse
/// plain requests. Runs on this Mac; the site sees a normal preview request.
enum SystemLinkPreview {
    struct Preview: Sendable { let title: String?; let image: Data? }

    @MainActor
    static func fetch(_ url: URL, timeout: TimeInterval = 15) async -> Preview? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Preview?, Never>) in
            let provider = LPMetadataProvider()
            provider.timeout = timeout
            provider.startFetchingMetadata(for: url) { metadata, _ in
                _ = provider  // keep the provider alive until it answers
                guard let metadata else { continuation.resume(returning: nil); return }
                let title = metadata.title
                guard let images = metadata.imageProvider ?? metadata.iconProvider else {
                    continuation.resume(returning: Preview(title: title, image: nil)); return
                }
                images.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    // Store as PNG so every format the preview returns opens the same way.
                    var png: Data?
                    if let data, let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff) { png = rep.representation(using: .png, properties: [:]) }
                    continuation.resume(returning: Preview(title: title, image: png ?? data))
                }
            }
        }
    }
}
