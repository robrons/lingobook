import Foundation
import ZIPFoundation

/// Service for parsing and extracting content from EPUB files
class EPUBService {
    
    // MARK: - Types
    
    struct EPUBContent {
        var title: String
        var author: String
        var coverData: Data?
        var chapters: [Chapter]
        var tableOfContents: [TOCItem]
    }
    
    struct Chapter: Identifiable, Hashable {
        let id: String
        var title: String
        var htmlContent: String
        var href: String
        var index: Int
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
        
        static func == (lhs: Chapter, rhs: Chapter) -> Bool {
            lhs.id == rhs.id
        }
    }
    
    struct TOCItem: Identifiable {
        let id: String
        var label: String
        var href: String
        var level: Int
    }
    
    // MARK: - Parsing
    
    /// Parse an EPUB file from Data
    func parse(epubData: Data) throws -> EPUBContent {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Create temp directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Write EPUB data to temp file
        let epubFile = tempDir.appendingPathComponent("book.epub")
        try epubData.write(to: epubFile)
        
        // Extract EPUB
        let extractDir = tempDir.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        // An EPUB is a zip. If it won't unzip, it isn't one — and ZIPFoundation's own
        // errors ("Invalid CRC32 checksum") mean nothing to someone opening a book.
        do {
            try FileManager.default.unzipItem(at: epubFile, to: extractDir)
        } catch {
            throw EPUBError.invalidContainer
        }
        
        // Parse container.xml to find OPF file
        let containerPath = extractDir.appendingPathComponent("META-INF/container.xml")
        let opfPath = try parseContainer(at: containerPath, baseURL: extractDir)
        
        // Parse OPF file
        let (metadata, manifest, spine) = try parseOPF(at: opfPath)

        // An empty spine means the OPF parsed but told us nothing about reading order.
        guard !spine.isEmpty else { throw EPUBError.invalidOPF }

        // Get the base directory for content files
        let contentBaseURL = opfPath.deletingLastPathComponent()
        
        // Extract cover image
        let coverData = extractCover(manifest: manifest, baseURL: contentBaseURL)
        
        // Load chapters from spine
        var chapters: [Chapter] = []
        for (index, itemRef) in spine.enumerated() {
            if let manifestItem = manifest[itemRef],
               let href = manifestItem["href"] {
                let chapterURL = contentBaseURL.appendingPathComponent(href)
                if let htmlContent = try? String(contentsOf: chapterURL, encoding: .utf8) {
                    let title = extractTitle(from: htmlContent) ?? "Chapter \(index + 1)"
                    chapters.append(Chapter(
                        id: itemRef,
                        title: title,
                        htmlContent: htmlContent,
                        href: href,
                        index: index
                    ))
                }
            }
        }
        
        // Every spine entry failed to resolve to a file we could read. Previously this
        // returned an empty book and the reader just showed a blank page forever.
        guard !chapters.isEmpty else { throw EPUBError.noContent }

        // Parse TOC (NCX or NAV)
        let toc = parseTOC(manifest: manifest, baseURL: contentBaseURL)

        return EPUBContent(
            title: metadata["title"] ?? "Unknown Title",
            author: metadata["creator"] ?? "Unknown Author",
            coverData: coverData,
            chapters: chapters,
            tableOfContents: toc
        )
    }
    
    // MARK: - Private Methods
    
    private func parseContainer(at url: URL, baseURL: URL) throws -> URL {
        // A missing META-INF/container.xml is an invalid container, not a file-system
        // mishap — report it as the former.
        guard let data = try? Data(contentsOf: url) else {
            throw EPUBError.invalidContainer
        }
        let parser = ContainerXMLParser(data: data)
        guard let rootfile = parser.parse() else {
            throw EPUBError.invalidContainer
        }
        return baseURL.appendingPathComponent(rootfile)
    }
    
    private func parseOPF(at url: URL) throws -> (metadata: [String: String], manifest: [String: [String: String]], spine: [String]) {
        guard let data = try? Data(contentsOf: url) else {
            throw EPUBError.invalidOPF
        }
        let parser = OPFParser(data: data)
        return parser.parse()
    }
    
    private func extractCover(manifest: [String: [String: String]], baseURL: URL) -> Data? {
        // Look for cover image in manifest
        for (_, item) in manifest {
            if let properties = item["properties"], properties.contains("cover-image"),
               let href = item["href"] {
                let coverURL = baseURL.appendingPathComponent(href)
                return try? Data(contentsOf: coverURL)
            }
            
            // Also check for id containing "cover"
            if let id = item["id"], id.lowercased().contains("cover"),
               let mediaType = item["media-type"], mediaType.starts(with: "image/"),
               let href = item["href"] {
                let coverURL = baseURL.appendingPathComponent(href)
                return try? Data(contentsOf: coverURL)
            }
        }
        return nil
    }
    
    private func extractTitle(from html: String) -> String? {
        // Simple regex to extract title from <title> or <h1>/<h2> tags
        if let titleRange = html.range(of: "<title[^>]*>(.*?)</title>", options: .regularExpression) {
            let titleHTML = String(html[titleRange])
            return titleHTML
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        if let h1Range = html.range(of: "<h1[^>]*>(.*?)</h1>", options: .regularExpression) {
            let h1HTML = String(html[h1Range])
            return h1HTML
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return nil
    }
    
    private func parseTOC(manifest: [String: [String: String]], baseURL: URL) -> [TOCItem] {
        // Look for NCX file
        for (_, item) in manifest {
            if let mediaType = item["media-type"], mediaType == "application/x-dtbncx+xml",
               let href = item["href"] {
                let ncxURL = baseURL.appendingPathComponent(href)
                if let data = try? Data(contentsOf: ncxURL) {
                    let parser = NCXParser(data: data)
                    return parser.parse()
                }
            }
        }
        return []
    }
    
    // MARK: - Text Extraction
    
    /// Extract plain text from HTML content, grouped by paragraphs, in document order.
    func extractParagraphs(from html: String) -> [String] {
        if let blocks = XHTMLTextParser(html: html).parse(), !blocks.isEmpty {
            return blocks
                .map { $0.strippingLeadingDashes() }
                .filter { !$0.isEmpty }
        }
        return legacyExtractParagraphs(from: html)
    }

    /// Fallback for documents XHTMLTextParser can't parse (malformed markup, unclosed tags).
    ///
    /// Matches block tags one type at a time, so it can reorder text and double-count
    /// nested blocks — but a flawed page beats a blank one when the markup is broken.
    private func legacyExtractParagraphs(from html: String) -> [String] {
        var paragraphs: [String] = []
        
        // Remove script and style content
        var cleanHTML = html
        cleanHTML = cleanHTML.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
        cleanHTML = cleanHTML.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
        
        // Split by block-level elements
        let blockTags = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]
        
        for tag in blockTags {
            let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let range = NSRange(cleanHTML.startIndex..., in: cleanHTML)
                let matches = regex.matches(in: cleanHTML, range: range)
                
                for match in matches {
                    if let contentRange = Range(match.range(at: 1), in: cleanHTML) {
                        let content = String(cleanHTML[contentRange])
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            .replacingOccurrences(of: "&nbsp;", with: " ")
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&quot;", with: "\"")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        let stripped = content.strippingLeadingDashes()
                        if !stripped.isEmpty {
                            paragraphs.append(stripped)
                        }
                    }
                }
            }
        }
        
        // If no paragraphs found, fall back to simple text extraction
        if paragraphs.isEmpty {
            let plainText = cleanHTML
                .replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
                .components(separatedBy: "\n")
                .map { $0.strippingLeadingDashes() }
                .filter { !$0.isEmpty }
            paragraphs = plainText
        }
        
        return paragraphs
    }
    
    /// Extract all text as a single string
    func extractPlainText(from html: String) -> String {
        return extractParagraphs(from: html).joined(separator: "\n\n")
    }
}

// MARK: - Errors

enum EPUBError: Error, LocalizedError {
    case invalidContainer
    case invalidOPF
    case noContent

    /// Written for whoever is holding the book, not whoever wrote the parser.
    var errorDescription: String? {
        switch self {
        case .invalidContainer:
            return "This file doesn't look like an EPUB. Its container is missing or unreadable."
        case .invalidOPF:
            return "This EPUB's package file is damaged, so its list of chapters couldn't be read."
        case .noContent:
            return "This EPUB doesn't contain any readable chapters."
        }
    }
}

// MARK: - XML Parsers

class ContainerXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var rootfile: String?
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rootfile
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            rootfile = attributeDict["full-path"]
        }
    }
}

class OPFParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var metadata: [String: String] = [:]
    private var manifest: [String: [String: String]] = [:]
    private var spine: [String] = []
    
    private var currentElement = ""
    private var currentText = ""
    private var inMetadata = false
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() -> (metadata: [String: String], manifest: [String: [String: String]], spine: [String]) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (metadata, manifest, spine)
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""
        
        switch localName {
        case "metadata":
            inMetadata = true
        case "item":
            if let id = attributeDict["id"] {
                manifest[id] = attributeDict
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        
        if localName == "metadata" {
            inMetadata = false
        }
        
        if inMetadata {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                switch localName {
                case "title":
                    metadata["title"] = trimmed
                case "creator":
                    metadata["creator"] = trimmed
                case "language":
                    metadata["language"] = trimmed
                default:
                    break
                }
            }
        }
    }
}

class NCXParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var items: [EPUBService.TOCItem] = []
    private var currentLabel = ""
    private var currentContent = ""
    private var currentText = ""
    private var inText = false
    private var depth = 0
    private var navPointDepth = 0
    
    init(data: Data) {
        self.data = data
    }
    
    func parse() -> [EPUBService.TOCItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        switch elementName {
        case "navPoint":
            navPointDepth = depth
            depth += 1
            currentLabel = ""
            currentContent = ""
        case "text":
            inText = true
            currentText = ""
        case "content":
            currentContent = attributeDict["src"] ?? ""
        default:
            break
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            currentText += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "text":
            inText = false
            currentLabel = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        case "navPoint":
            depth -= 1
            if !currentLabel.isEmpty {
                items.append(EPUBService.TOCItem(
                    id: UUID().uuidString,
                    label: currentLabel,
                    href: currentContent,
                    level: navPointDepth
                ))
            }
        default:
            break
        }
    }
}

// MARK: - Extensions

extension String {
    /// Removes leading dashes, hyphens, and whitespace commonly found in dialogues
    func strippingLeadingDashes() -> String {
        var str = self.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = str.first, ("-—–_".contains(first) || first.isWhitespace) {
            str.removeFirst()
        }
        return str
    }
}
