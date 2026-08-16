//
//  DOCXWriter.swift
//  FileForge
//
//  Writes a clean, flowing .docx (OOXML) from extracted text.
//
//  Why not just let LibreOffice do it:
//  ──────────────────────────────────────────────────────────────────────────
//  LibreOffice's `writer_pdf_import` reproduces a PDF's exact visual layout by
//  wrapping every line in an absolutely-positioned text frame — a real payslip
//  came through as 388 floating text boxes holding 204 runs of text. Word
//  renders those stacked and overlapping, so the document opens looking BLANK
//  even though every word is technically present. Its `TextBoxes=false` import
//  option is documented but ignored in practice (verified: identical output).
//
//  That is a data-loss-shaped bug from the user's point of view, and the
//  fidelity it buys is worthless for the actual job — nobody converts to Word
//  to preserve pixel positions; they convert to EDIT the text.
//
//  So FileForge extracts the text with PDFKit (which orders it correctly) and
//  writes the .docx itself. The result is editable prose in real paragraphs.
//
//  A .docx is a ZIP of XML parts: content types, package rels, and a document
//  part holding the body.
//
//  Author: Ibrahim Sultan
//

import Foundation

enum DOCXWriter {

    /// Build a .docx at `output` from `paragraphs`, one Word paragraph each.
    ///
    /// - Parameter title: optional heading rendered above the body.
    static func write(paragraphs: [String], title: String?, to output: URL) throws {
        let staging = try OutputNamer.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let fm = FileManager.default
        for path in ["_rels", "word", "word/_rels"] {
            try fm.createDirectory(at: staging.appendingPathComponent(path),
                                   withIntermediateDirectories: true)
        }

        try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
            </Types>
            """.write(to: staging.appendingPathComponent("[Content_Types].xml"),
                      atomically: true, encoding: .utf8)

        try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            </Relationships>
            """.write(to: staging.appendingPathComponent("_rels/.rels"),
                      atomically: true, encoding: .utf8)

        try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """.write(to: staging.appendingPathComponent("word/_rels/document.xml.rels"),
                      atomically: true, encoding: .utf8)

        try stylesXML.write(to: staging.appendingPathComponent("word/styles.xml"),
                            atomically: true, encoding: .utf8)

        var body = ""
        if let title, !title.isEmpty {
            body += paragraph(title, style: "Title")
        }
        for text in paragraphs {
            body += paragraph(text, style: nil)
        }
        // Word requires a section properties block; without it the document
        // opens with a repair prompt.
        body += """
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
            w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
            """

        try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>\(body)</w:body>
            </w:document>
            """.write(to: staging.appendingPathComponent("word/document.xml"),
                      atomically: true, encoding: .utf8)

        try zip(directory: staging, to: output)
    }

    // MARK: - Parts

    private static func paragraph(_ text: String, style: String?) -> String {
        let styleTag = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        guard !text.isEmpty else { return "<w:p>\(styleTag)</w:p>" }
        // `xml:space="preserve"` keeps leading indentation, which is what
        // holds a payslip's column alignment together once it's flowing text.
        return "<w:p>\(styleTag)<w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r></w:p>"
    }

    /// Escape XML metacharacters, and strip control characters that are illegal
    /// in XML 1.0 — PDF text extraction can yield stray form feeds, which make
    /// Word declare the file corrupt.
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.unicodeScalars {
            switch character {
            case "&":  result += "&amp;"
            case "<":  result += "&lt;"
            case ">":  result += "&gt;"
            case "\"": result += "&quot;"
            case "'":  result += "&apos;"
            default:
                // Allow tab, newline, carriage return; drop other C0 controls.
                if character.value >= 0x20 || character.value == 0x09
                    || character.value == 0x0A || character.value == 0x0D {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result
    }

    private static let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults><w:rPrDefault><w:rPr>
        <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri"/><w:sz w:val="22"/>
        </w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
        <w:name w:val="Normal"/><w:qFormat/>
        </w:style>
        <w:style w:type="paragraph" w:styleId="Title">
        <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/>
        <w:pPr><w:spacing w:after="240"/></w:pPr>
        <w:rPr><w:b/><w:sz w:val="32"/></w:rPr>
        </w:style>
        </w:styles>
        """

    private static func zip(directory: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", "-X", output.path, "."]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output.path) else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "zip failed"
            throw ForgeError.toolFailed("DOCX", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
