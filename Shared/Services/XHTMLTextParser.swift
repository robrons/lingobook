import Foundation

/// Extracts readable text blocks from an EPUB chapter's XHTML, in document order.
///
/// The rule is simply block vs. inline: any block-level boundary (start *or* end)
/// flushes whatever text has accumulated, while inline elements (`<em>`, `<a>`, …)
/// let it keep accumulating. That single rule keeps text in document order and makes
/// duplication impossible — `<blockquote><p>x</p></blockquote>` emits "x" once,
/// because the buffer is already empty by the time the blockquote closes.
///
/// Returns nil if the document can't be parsed, so the caller can fall back.
final class XHTMLTextParser: NSObject, XMLParserDelegate {

    private let html: String
    private var blocks: [String] = []
    private var buffer = ""
    private var skipDepth = 0
    private var failed = false

    init(html: String) {
        self.html = html
    }

    // MARK: - Tag classification

    /// Elements that flow within a paragraph and must not break it.
    private static let inlineTags: Set<String> = [
        "span", "em", "strong", "i", "b", "u", "a", "small", "sup", "sub", "code",
        "cite", "q", "abbr", "acronym", "time", "font", "tt", "s", "strike", "big",
        "mark", "ruby", "rt", "rp", "bdi", "bdo", "wbr", "label", "var", "kbd",
        "samp", "dfn", "ins", "del", "img", "image", "svg", "br", "a:link"
    ]

    /// Elements whose contents are never reader-facing text.
    private static let skipTags: Set<String> = ["script", "style", "head"]

    // MARK: - Parsing

    func parse() -> [String]? {
        guard let data = preparedDocument().data(using: .utf8) else { return nil }

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false

        let succeeded = parser.parse()
        guard succeeded, !failed else { return nil }
        return blocks
    }

    /// Strips the prolog, resolves named entities, and wraps everything in a single
    /// synthetic root so fragments (and multi-root documents) parse as valid XML.
    private func preparedDocument() -> String {
        var doc = html
        doc = doc.replacingOccurrences(
            of: "<\\?xml[^>]*\\?>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        doc = doc.replacingOccurrences(
            of: "<!DOCTYPE[^>\\[]*(\\[[^\\]]*\\])?[^>]*>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return "<lingobookroot>" + substitutingEntities(in: doc) + "</lingobookroot>"
    }

    // MARK: - Entities

    /// XMLParser resolves these itself; leave them alone.
    private static let xmlBuiltinEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// Named HTML entities rewritten as numeric references, which XMLParser understands.
    /// Anything undeclared would otherwise abort the parse.
    private static let namedEntities: [String: String] = [
        "nbsp": "&#160;", "iexcl": "&#161;", "cent": "&#162;", "pound": "&#163;",
        "curren": "&#164;", "yen": "&#165;", "brvbar": "&#166;", "sect": "&#167;",
        "uml": "&#168;", "copy": "&#169;", "ordf": "&#170;", "laquo": "&#171;",
        "not": "&#172;", "shy": "&#173;", "reg": "&#174;", "macr": "&#175;",
        "deg": "&#176;", "plusmn": "&#177;", "sup2": "&#178;", "sup3": "&#179;",
        "acute": "&#180;", "micro": "&#181;", "para": "&#182;", "middot": "&#183;",
        "cedil": "&#184;", "sup1": "&#185;", "ordm": "&#186;", "raquo": "&#187;",
        "frac14": "&#188;", "frac12": "&#189;", "frac34": "&#190;", "iquest": "&#191;",
        "Agrave": "&#192;", "Aacute": "&#193;", "Acirc": "&#194;", "Atilde": "&#195;",
        "Auml": "&#196;", "Aring": "&#197;", "AElig": "&#198;", "Ccedil": "&#199;",
        "Egrave": "&#200;", "Eacute": "&#201;", "Ecirc": "&#202;", "Euml": "&#203;",
        "Igrave": "&#204;", "Iacute": "&#205;", "Icirc": "&#206;", "Iuml": "&#207;",
        "ETH": "&#208;", "Ntilde": "&#209;", "Ograve": "&#210;", "Oacute": "&#211;",
        "Ocirc": "&#212;", "Otilde": "&#213;", "Ouml": "&#214;", "times": "&#215;",
        "Oslash": "&#216;", "Ugrave": "&#217;", "Uacute": "&#218;", "Ucirc": "&#219;",
        "Uuml": "&#220;", "Yacute": "&#221;", "THORN": "&#222;", "szlig": "&#223;",
        "agrave": "&#224;", "aacute": "&#225;", "acirc": "&#226;", "atilde": "&#227;",
        "auml": "&#228;", "aring": "&#229;", "aelig": "&#230;", "ccedil": "&#231;",
        "egrave": "&#232;", "eacute": "&#233;", "ecirc": "&#234;", "euml": "&#235;",
        "igrave": "&#236;", "iacute": "&#237;", "icirc": "&#238;", "iuml": "&#239;",
        "eth": "&#240;", "ntilde": "&#241;", "ograve": "&#242;", "oacute": "&#243;",
        "ocirc": "&#244;", "otilde": "&#245;", "ouml": "&#246;", "divide": "&#247;",
        "oslash": "&#248;", "ugrave": "&#249;", "uacute": "&#250;", "ucirc": "&#251;",
        "uuml": "&#252;", "yacute": "&#253;", "thorn": "&#254;", "yuml": "&#255;",
        "OElig": "&#338;", "oelig": "&#339;", "Scaron": "&#352;", "scaron": "&#353;",
        "Yuml": "&#376;", "fnof": "&#402;", "circ": "&#710;", "tilde": "&#732;",
        "ensp": "&#8194;", "emsp": "&#8195;", "thinsp": "&#8201;",
        "zwnj": "&#8204;", "zwj": "&#8205;", "lrm": "&#8206;", "rlm": "&#8207;",
        "ndash": "&#8211;", "mdash": "&#8212;", "lsquo": "&#8216;", "rsquo": "&#8217;",
        "sbquo": "&#8218;", "ldquo": "&#8220;", "rdquo": "&#8221;", "bdquo": "&#8222;",
        "dagger": "&#8224;", "Dagger": "&#8225;", "bull": "&#8226;", "hellip": "&#8230;",
        "permil": "&#8240;", "prime": "&#8242;", "Prime": "&#8243;",
        "lsaquo": "&#8249;", "rsaquo": "&#8250;", "oline": "&#8254;", "frasl": "&#8260;",
        "euro": "&#8364;", "trade": "&#8482;",
        "larr": "&#8592;", "uarr": "&#8593;", "rarr": "&#8594;", "darr": "&#8595;",
        "harr": "&#8596;", "spades": "&#9824;", "clubs": "&#9827;",
        "hearts": "&#9829;", "diams": "&#9830;", "loz": "&#9674;"
    ]

    private static let entityPattern = try? NSRegularExpression(
        pattern: "&([a-zA-Z][a-zA-Z0-9]{1,31});"
    )

    private func substitutingEntities(in text: String) -> String {
        guard let regex = Self.entityPattern else { return text }

        let source = text as NSString
        var result = ""
        var cursor = 0

        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }

            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))

            let name = source.substring(with: match.range(at: 1))
            if Self.xmlBuiltinEntities.contains(name) {
                result += source.substring(with: match.range)
            } else if let numeric = Self.namedEntities[name] {
                result += numeric
            }
            // Unknown entity: dropped, since keeping it would abort the parse.

            cursor = match.range.location + match.range.length
        }

        result += source.substring(from: cursor)
        return result
    }

    // MARK: - Buffer

    private func flush() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !trimmed.isEmpty else { return }

        // HTML collapses runs of whitespace; source indentation shouldn't reach the reader.
        let collapsed = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        blocks.append(collapsed)
    }

    private func localName(_ elementName: String) -> String {
        (elementName.components(separatedBy: ":").last ?? elementName).lowercased()
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if skipDepth > 0 {
            skipDepth += 1
            return
        }

        let tag = localName(elementName)

        if Self.skipTags.contains(tag) {
            flush()
            skipDepth = 1
            return
        }
        if tag == "br" {
            buffer += " "
            return
        }
        if Self.inlineTags.contains(tag) { return }

        flush()
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if skipDepth > 0 {
            skipDepth -= 1
            return
        }

        let tag = localName(elementName)
        if tag == "br" || Self.inlineTags.contains(tag) { return }

        flush()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
