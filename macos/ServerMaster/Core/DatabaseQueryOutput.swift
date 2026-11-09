import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// MariaDB XML distinguishes SQL NULL from the text "NULL" and preserves empty
/// strings and escaped tabs/newlines. Plain batch TSV cannot express that distinction.
nonisolated enum DatabaseQueryOutput {
    static func decode(_ output: String) throws -> DatabaseService.QueryResult {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(message: String(localized: "Query executed."))
        }
        // Each SELECT in a multi-statement command emits a separate XML document.
        // Show the final result, never combine rows belonging to different tables.
        let pieces = output.components(separatedBy: "<?xml")
        let documents: [String]
        if pieces.count > 1 {
            guard pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalid }
            documents = pieces.dropFirst().map { "<?xml" + $0 }
        } else { documents = [output] }
        var result = DatabaseService.QueryResult()
        for document in documents {
            let delegate = ResultParser()
            let parser = XMLParser(data: Data(try preservingCarriageReturns(document).utf8))
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), delegate.valid, delegate.seenResult else { throw Failure.invalid }
            result = .init(columns: delegate.columns, rows: delegate.rows,
                           message: String(localized: "Rows: \(String(delegate.rows.count))"))
        }
        if documents.count > 1 {
            result.message += " · " + String(localized: "Showing the last of \(documents.count) result sets.")
        }
        return result
    }

    enum Failure: Error { case invalid }

    /// XML normalizes literal CR/CRLF. The CLI emits field contents with raw CR,
    /// so protect those characters as references before the XML parser sees them.
    /// Field data cannot contain literal '<': the client escapes it as '&lt;'.
    private static func preservingCarriageReturns(_ xml: String) throws -> String {
        let pattern = try NSRegularExpression(pattern: #"<field\b[^>]*>([^<]*)</field>"#)
        let result = NSMutableString(string: xml)
        for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).reversed() {
            let range = match.range(at: 1)
            let text = result.substring(with: range)
            if text.contains("\r") { result.replaceCharacters(in: range, with: text.replacingOccurrences(of: "\r", with: "&#13;")) }
        }
        return result as String
    }

    private final class ResultParser: NSObject, XMLParserDelegate {
        var columns: [String] = []
        var rows: [[String?]] = []
        var valid = true
        var seenResult = false
        private var row: [String?] = []
        private var names: [String] = []
        private var text = ""
        private var isNull = false
        private var inField = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "resultset":
                if seenResult { valid = false }
                seenResult = true
            case "row": row = []; names = []
            case "field":
                guard let column = attributes["name"] else { valid = false; return }
                names.append(column)
                text = ""
                isNull = attributes["xsi:nil"] == "true" || attributes["xsi:nil"] == "1"
                inField = true
            default: valid = false
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inField { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "field" {
                row.append(isNull ? nil : text)
                inField = false
            } else if name == "row" {
                if rows.isEmpty { columns = names }
                if names != columns || row.count != columns.count { valid = false }
                rows.append(row)
            }
        }
    }
}
