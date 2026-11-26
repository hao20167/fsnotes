//
//  Markdown.swift
//  FSNotes
//
//  Created by Wonsup Yoon on 05/10/2019.
//  Copyright © 2019 Oleksandr Glushchenko. All rights reserved.
//

import Foundation
import libcmark_gfm

/// Replaces Markdown horizontal-rule lines without touching fenced code blocks.
func replaceHorizontalRulesOutsideCodeBlocks(in markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var result: [String] = []
    var fenceLength: Int?

    for (index, line) in lines.enumerated() {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let content = String(line.dropFirst(min(leadingSpaces, 3)))
        let characters = Array(content)

        if let currentFenceLength = fenceLength {
            if characters.first == "`",
               characters.prefix(while: { $0 == "`" }).count >= currentFenceLength {
                fenceLength = nil
            }
        } else if characters.first == "`" {
            let length = characters.prefix(while: { $0 == "`" }).count
            if length >= 3 {
                fenceLength = length
            }
        }

        // Keep the existing behavior for a standalone `---` line, including
        // its requirement for a following newline, but only outside code.
        if fenceLength == nil && line == "---" && index > 0 && index < lines.count - 1 {
            result.append("<hr>")
        } else {
            result.append(line)
        }
    }

    return result.joined(separator: "\n")
}

/// Keeps LaTeX away from the Markdown parser so MathJax gets it verbatim: cmark would turn
/// `\\` into `\`, `\(` / `\[` into `(` / `[` and `_..._` into emphasis.
/// Each formula becomes an alphanumeric token; every further line of a multi-line formula gets
/// its own continuation token, so source line numbers (preview scroll sync) stay the same.
struct MathShield {
    private(set) var formulas = [String]()

    private static let token = "FSNMATH"
    private static let continuation = "FSNMATHC"

    private static let formulaRegex = try! NSRegularExpression(pattern: [
        #"(?<!\\)\$\$(?:(?!\n[ \t]*\n)[\s\S])+?\$\$"#,          // $$ … $$ (no blank line inside)
        #"(?<!\\)\\\[(?:(?!\n[ \t]*\n)[\s\S])+?\\\]"#,      // \[ … \]
        #"(?<!\\)\\\((?:(?!\n[ \t]*\n)[\s\S])+?\\\)"#,      // \( … \)
        #"(?<![\\$])\$(?=[^\s$])(?:\\.|[^$\\\n])+?(?<=[^\s\\])\$(?!\d)"#  // $ … $ on one line
    ].joined(separator: "|"))

    private static let continuationRegex = try! NSRegularExpression(pattern: #"(?:<br />)?\n[ \t]*FSNMATHC"#)

    mutating func protect(_ markdown: String) -> String {
        let source = markdown as NSString
        let result = NSMutableString()
        var last = 0

        for match in MathShield.formulaRegex.matches(in: markdown, range: NSRange(location: 0, length: source.length)) {
            let formula = source.substring(with: match.range)
            let lines = formula.components(separatedBy: "\n")

            // Inside a blockquote the `>` markers are not part of the formula: leave it to cmark
            if lines.dropFirst().contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) { continue }

            result.append(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            result.append("\(MathShield.token)\(formulas.count)X")
            for line in lines.dropFirst() {
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                result.append("\n\(indent)\(MathShield.continuation)")
            }
            formulas.append(MathShield.inlineIfInText(formula, range: match.range, in: source))
            last = NSMaxRange(match.range)
        }
        guard !formulas.isEmpty else { return markdown }
        result.append(source.substring(from: last))
        return result as String
    }

    /// `$$…$$` inside a sentence stays in the sentence like in the editor (display style, not a
    /// centered block of its own); alone on its line it remains a centered display formula.
    private static func inlineIfInText(_ formula: String, range: NSRange, in source: NSString) -> String {
        guard formula.hasPrefix("$$"), formula.hasSuffix("$$"), formula.count > 4 else { return formula }
        let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: NSMaxRange(range), length: 0))
        let before = source.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
        let after = source.substring(with: NSRange(location: NSMaxRange(range), length: max(0, contentsEnd - NSMaxRange(range))))
        if before.trimmingCharacters(in: .whitespaces).isEmpty && after.trimmingCharacters(in: .whitespaces).isEmpty {
            return formula
        }
        return "\\(\\displaystyle " + formula.dropFirst(2).dropLast(2) + "\\)"
    }

    func restore(_ html: String) -> String {
        guard !formulas.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        MathShield.continuationRegex.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: "")

        var result = mutable as String
        for (index, formula) in formulas.enumerated() {
            // Escaped like cmark escapes text, so formulas in code come out unchanged
            let escaped = formula
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            // Own element per formula: the preview can typeset each one alone if the page fails
            result = result.replacingOccurrences(of: "\(MathShield.token)\(index)X", with: "<span class=\"fsn-math\">\(escaped)</span>")
        }
        return result
    }
}

func renderMarkdownHTML(markdown: String, sourcePositions: Bool = false) -> String? {
    var shield = MathShield()
    var markdown = markdown.replacingOccurrences(of: "{{TOC}}", with: "<div id=\"toc\"></div>")
    if UserDefaultsManagement.mathJaxPreview {
        markdown = shield.protect(markdown)
    }
        
    cmark_gfm_core_extensions_ensure_registered()
    
    guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES) else { return nil }
    defer { cmark_parser_free(parser) }

    if let ext = cmark_find_syntax_extension("table") {
        cmark_parser_attach_syntax_extension(parser, ext)
    }

    if let ext = cmark_find_syntax_extension("autolink") {
        cmark_parser_attach_syntax_extension(parser, ext)
    }

    if let ext = cmark_find_syntax_extension("strikethrough") {
        cmark_parser_attach_syntax_extension(parser, ext)
    }
    
    if let ext = cmark_find_syntax_extension("tasklist") {
        cmark_parser_attach_syntax_extension(parser, ext)
    }

    cmark_parser_feed(parser, markdown, markdown.utf8.count)
    guard let node = cmark_parser_finish(parser) else { return nil }
    let options = CMARK_OPT_HARDBREAKS | CMARK_OPT_UNSAFE | (sourcePositions ? CMARK_OPT_SOURCEPOS : 0)
    return shield.restore(String(cString: cmark_render_html(node, options, nil)))
}

func generateAlphabeticalString(length: Int) -> String {
    let alphabet = "abcdefghijklmnopqrstuvwxyz"
    var result = "@"
    let length = length - 2

    for _ in 0..<length {
        let randomIndex = Int.random(in: 0..<alphabet.count)
        let randomChar = alphabet[alphabet.index(alphabet.startIndex, offsetBy: randomIndex)]
        result.append(randomChar)
    }

    result.append("@")

    return result
}
