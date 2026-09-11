//
//  ErrorPages.swift
//  ServerMaster
//
//  Custom error pages, so a local folder behaves like a real server.
//

import Foundation

nonisolated struct HTTPErrorCode: Sendable {
    var code: Int
    var title: String
    var explanation: String
}

nonisolated enum ErrorPages {

    /// The codes pages are generated for.
    static let codes: [HTTPErrorCode] = [
        HTTPErrorCode(code: 400, title: String(localized: "Bad request"),
                      explanation: String(localized: "The server could not parse the request — it is probably malformed.")),
        HTTPErrorCode(code: 401, title: String(localized: "Authorization required"),
                      explanation: String(localized: "You need to sign in to open this page.")),
        HTTPErrorCode(code: 402, title: String(localized: "Payment required"),
                      explanation: String(localized: "Access to this resource requires payment.")),
        HTTPErrorCode(code: 403, title: String(localized: "Access denied"),
                      explanation: String(localized: "You do not have permission to view this resource.")),
        HTTPErrorCode(code: 404, title: String(localized: "Page not found"),
                      explanation: String(localized: "There is nothing at this address. The link may be outdated or misspelled.")),
        HTTPErrorCode(code: 405, title: String(localized: "Method not allowed"),
                      explanation: String(localized: "This address does not accept requests with that method.")),
        HTTPErrorCode(code: 408, title: String(localized: "Request timeout"),
                      explanation: String(localized: "The request took too long and the server stopped waiting.")),
        HTTPErrorCode(code: 409, title: String(localized: "Conflict"),
                      explanation: String(localized: "The request conflicts with the current state of the resource.")),
        HTTPErrorCode(code: 410, title: String(localized: "Gone"),
                      explanation: String(localized: "This page used to be here but was removed for good.")),
        HTTPErrorCode(code: 413, title: String(localized: "Payload too large"),
                      explanation: String(localized: "The payload is larger than allowed.")),
        HTTPErrorCode(code: 414, title: String(localized: "URI too long"),
                      explanation: String(localized: "The request URL is longer than the server accepts.")),
        HTTPErrorCode(code: 415, title: String(localized: "Unsupported media type"),
                      explanation: String(localized: "The server cannot process data of this type.")),
        HTTPErrorCode(code: 418, title: String(localized: "I am a teapot"),
                      explanation: String(localized: "Cannot brew coffee: this is a teapot.")),
        HTTPErrorCode(code: 429, title: String(localized: "Too many requests"),
                      explanation: String(localized: "Requests are coming in faster than allowed. Please wait a moment.")),
        HTTPErrorCode(code: 500, title: String(localized: "Internal server error"),
                      explanation: String(localized: "Something went wrong on the server. Check the ServerMaster console.")),
        HTTPErrorCode(code: 501, title: String(localized: "Not implemented"),
                      explanation: String(localized: "The server does not know how to do what was requested.")),
        HTTPErrorCode(code: 502, title: String(localized: "Bad gateway"),
                      explanation: String(localized: "The server got an invalid response from an upstream node.")),
        HTTPErrorCode(code: 503, title: String(localized: "Service unavailable"),
                      explanation: String(localized: "The server cannot handle the request right now. It may be restarting.")),
        HTTPErrorCode(code: 504, title: String(localized: "Gateway timeout"),
                      explanation: String(localized: "The upstream server did not respond in time.")),
        HTTPErrorCode(code: 505, title: String(localized: "HTTP version not supported"),
                      explanation: String(localized: "The server does not support this version of HTTP."))
    ]

    /// The name of the pages folder inside the engine's working directory.
    static let directoryName = "__sm_errors"

    /// The address the pages are served at.
    static let urlPrefix = "/__sm_errors"

    /// Write every page into the folder. Returns the path to the folder.
    @discardableResult
    static func write(for profile: ServerProfile, into parentDirectory: String) throws -> String {
        let directory = (parentDirectory as NSString).appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
        for item in codes {
            let html = page(for: item, profile: profile)
            let path = (directory as NSString).appendingPathComponent("\(item.code).html")
            try html.write(toFile: path, atomically: true, encoding: .utf8)
        }
        // A fallback page for a code that is not in the list.
        let fallback = HTTPErrorCode(code: 0,
                                     title: String(localized: "Something went wrong"),
                                     explanation: String(localized: "The server returned an error that has no dedicated page."))
        try page(for: fallback, profile: profile)
            .write(toFile: (directory as NSString).appendingPathComponent("error.html"),
                   atomically: true, encoding: .utf8)
        return directory
    }

    /// One page — self-contained HTML, with no external resources.
    static func page(for item: HTTPErrorCode, profile: ServerProfile) -> String {
        let accent = sanitizeColor(profile.errorPageAccent)
        let footer = profile.errorPageFooter.isEmpty
            ? profile.name
            : profile.errorPageFooter
        let code = item.code == 0 ? "" : String(item.code)
        let homeLabel = String(localized: "Home")
        let backLabel = String(localized: "Back")
        let language = Locale.current.language.languageCode?.identifier ?? "ru"

        return """
        <!DOCTYPE html>
        <html lang="\(language)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(code.isEmpty ? "" : code + " — ")\(escape(item.title))</title>
        <style>
          :root {
            --bg: #ffffff; --fg: #111827; --muted: #6b7280;
            --line: #e5e7eb; --accent: \(accent);
          }
          @media (prefers-color-scheme: dark) {
            :root { --bg: #0b0f17; --fg: #e5e7eb; --muted: #9ca3af; --line: #1f2937; }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; display: flex;
            align-items: center; justify-content: center;
            background: var(--bg); color: var(--fg);
            font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            padding: 32px;
          }
          .card { max-width: 480px; width: 100%; text-align: center; }
          .code {
            font-size: clamp(64px, 18vw, 120px); font-weight: 700; line-height: 1;
            letter-spacing: -0.04em; color: var(--accent); margin: 0 0 8px;
          }
          h1 { font-size: 22px; font-weight: 600; margin: 0 0 12px; }
          p { color: var(--muted); margin: 0 0 28px; }
          .actions { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
          a {
            display: inline-block; padding: 9px 18px; border-radius: 8px;
            text-decoration: none; font-size: 14px; font-weight: 500;
            border: 1px solid var(--line); color: var(--fg);
          }
          a.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
          footer {
            margin-top: 32px; padding-top: 18px; border-top: 1px solid var(--line);
            font-size: 12px; color: var(--muted);
          }
        </style>
        </head>
        <body>
          <div class="card">
            \(code.isEmpty ? "" : "<div class=\"code\">\(String(code))</div>")
            <h1>\(escape(item.title))</h1>
            <p>\(escape(item.explanation))</p>
            <div class="actions">
              <a class="primary" href="/">\(homeLabel)</a>
              <a href="javascript:history.back()">\(backLabel)</a>
            </div>
            <footer>\(escape(footer))</footer>
          </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    /// The profile name and the caption end up in the HTML — escape them.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The colour is substituted into CSS — only a genuine HEX gets through.
    static func sanitizeColor(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let isHex = (body.count == 3 || body.count == 6)
            && body.allSatisfy { $0.isHexDigit }
        return isHex ? "#" + body : "#3B82F6"
    }
}
