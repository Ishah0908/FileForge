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
import AppKit

enum DOCXWriter {

    /// Build a .docx from reconstructed page layout, preserving tables.
    ///
    /// Consecutive table rows are merged into ONE Word table so the columns
    /// line up as a unit — emitting a separate one-row table per line would
    /// let each row pick its own widths and the alignment would collapse,
    /// which is the whole thing we're trying to keep.
    static func write(layouts: [LayoutAnalyzer.PageLayout], to output: URL) throws {
        var body = ""
        var pendingRows: [[String]] = []

        /// Flush buffered rows as a single table.
        var pendingWeights: [Double] = []
        func flushTable() {
            guard !pendingRows.isEmpty else { return }
            let columnCount = pendingRows.map(\.count).max() ?? 1

            // Drop columns that are empty in EVERY row of this table.
            //
            // Column detection runs over the whole page, so a table using four
            // of the page's eight column positions still gets eight cells per
            // row — and the four empty ones eat width the real text needs,
            // which is what wraps a name down a narrow strip. Removing them
            // here (per table, not per page) gives the surviving columns their
            // space back while keeping alignment within the table intact.
            var used: [Int] = []
            for index in 0..<columnCount {
                let hasContent = pendingRows.contains { row in
                    index < row.count && !row[index].isEmpty
                }
                if hasContent { used.append(index) }
            }
            if used.isEmpty { pendingRows = []; return }

            let compactRows = pendingRows.map { row in
                used.map { index in index < row.count ? row[index] : "" }
            }
            // Keep each surviving column's share, renormalized to sum to 1.
            var compactWeights: [Double] = []
            if pendingWeights.count == columnCount {
                let kept = used.map { pendingWeights[$0] }
                let total = kept.reduce(0, +)
                if total > 0 { compactWeights = kept.map { $0 / total } }
            }

            body += table(rows: compactRows, columnCount: used.count, weights: compactWeights)
            pendingRows = []
        }

        for (index, layout) in layouts.enumerated() {
            pendingWeights = layout.columnWeights
            for block in layout.blocks {
                switch block {
                case .row(let cells):
                    pendingRows.append(cells)
                case .paragraph(let text):
                    flushTable()
                    body += paragraph(text, style: nil)
                }
            }
            flushTable()
            // Page break between source pages, so a two-page payslip stays two
            // pages rather than reflowing into one.
            if index < layouts.count - 1 {
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        guard !body.isEmpty else {
            throw ForgeError.nothingFound("no content to write")
        }
        try writePackage(body: body, to: output)
    }

    /// Build a .docx at `output` from `paragraphs`, one Word paragraph each.
    ///
    /// - Parameter title: optional heading rendered above the body.
    static func write(paragraphs: [String], title: String?, to output: URL) throws {
        var body = ""
        if let title, !title.isEmpty {
            body += paragraph(title, style: "Title")
        }
        for text in paragraphs {
            body += paragraph(text, style: nil)
        }
        try writePackage(body: body, to: output)
    }

    // MARK: - Package

    /// Assemble the OOXML package around an already-built `<w:body>` payload.
    private static func writePackage(body: String, to output: URL) throws {
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

        // Word requires a section properties block; without it the document
        // opens with a repair prompt.
        let sectionProperties = """
            <w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
            <w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" \
            w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
            """

        try """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:body>\(body)\(sectionProperties)</w:body>
            </w:document>
            """.write(to: staging.appendingPathComponent("word/document.xml"),
                      atomically: true, encoding: .utf8)

        try zip(directory: staging, to: output)
    }

    // MARK: - Parts

    /// Render buffered rows as one Word table.
    ///
    /// Borderless by default: the source PDF's columns were created by
    /// alignment, not ruled lines, so drawing borders would add structure the
    /// original never had. The table is what holds the columns in place; it
    /// stays invisible unless the user turns borders on in Word.
    ///
    /// Column widths come from `weights` — each column's share of the ORIGINAL
    /// page width — spread across the usable 10,080 twips (8.5in minus 0.75in
    /// margins). Dividing evenly instead makes a wide name column as narrow as
    /// a numeric one, and Word then wraps "Ibrahimuddin" down a vertical
    /// strip. `tblLayout fixed` keeps Word from re-flowing the widths around
    /// the longest cell.
    private static func table(rows: [[String]],
                              columnCount: Int,
                              weights: [Double]) -> String {
        guard columnCount > 0 else { return "" }
        let usableWidth = 10080

        // Every column needs enough width for its longest cell, or Word wraps
        // that text one or two characters per line — the "Fe / d / er / al"
        // shredding that makes the document unreadable. Estimate the demand
        // from the content, then reconcile it with the geometry.
        //
        // ~110 twips per character is a conservative width for 11pt Calibri
        // (a real character averages nearer 100), so this errs toward giving a
        // column slightly too much rather than too little.
        // MEASURE the text rather than estimating from character counts.
        //
        // Character-count heuristics were the source of a long tail of bugs
        // here: "Employee Name" and "3241312" have similar lengths but very
        // different widths, so estimated columns came out too narrow and Word
        // shredded the text down a two-character strip. NSAttributedString
        // reports the real typeset width in points; converting at 20 twips per
        // point gives a width that is right by construction.
        var demand = [Int](repeating: 0, count: columnCount)
        let font = NSFont(name: "Calibri", size: 11) ?? NSFont.systemFont(ofSize: 11)
        for index in 0..<columnCount {
            var widest: CGFloat = 0
            for row in rows where index < row.count && !row[index].isEmpty {
                let measured = NSAttributedString(string: row[index],
                                                  attributes: [.font: font]).size().width
                widest = max(widest, measured)
            }
            guard widest > 0 else { continue }
            // 20 twips per point, plus cell padding. Capped so one long
            // sentence wraps over a few lines instead of claiming the page.
            demand[index] = min(Int(widest * 20) + 300, 5200)
        }

        // Content demand is the primary signal, geometry only breaks ties.
        //
        // Earlier attempts led with the original page proportions and topped
        // columns up to their demand; that starved whichever column the
        // geometry happened to rate narrow, so "Employee Name" shredded into
        // "Employe / e Name" while its neighbour had room to spare. Sizing by
        // what each column must FIT, then nudging by the original proportions,
        // keeps every column legible — which matters more in an editable
        // document than reproducing exact page positions.
        // Size PURELY by content. The original page geometry is deliberately
        // ignored here: blending the two kept starving whichever column the
        // geometry rated narrow, shredding its text one or two characters per
        // line. In an editable document, a column wide enough to read beats a
        // column faithful to the original x position.
        var widths = demand.map { max(600, $0) }

        // Share the page in proportion to what each column needs, so a column
        // that wants twice the space of its neighbour gets twice the space —
        // and everything scales together rather than one column absorbing the
        // shortfall.
        let totalDemand = widths.reduce(0, +)
        if totalDemand > 0 {
            widths = widths.map { max(600, Int(Double(usableWidth) * Double($0) / Double(totalDemand))) }
        }

        // Rounding and the 600-twip floor can push the total off the page
        // width; trim the roomiest column until it fits, then hand any slack
        // to that same column.
        var total = widths.reduce(0, +)
        while total > usableWidth,
              let widest = widths.indices.max(by: { widths[$0] < widths[$1] }),
              widths[widest] > 600 {
            widths[widest] -= min(total - usableWidth, widths[widest] - 600)
            total = widths.reduce(0, +)
        }
        if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] += usableWidth - widths.reduce(0, +)
        }

        var xml = """
            <w:tbl><w:tblPr>\
            <w:tblW w:w="\(usableWidth)" w:type="dxa"/>\
            <w:tblLayout w:type="fixed"/>\
            <w:tblBorders>\
            <w:top w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            <w:left w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            <w:bottom w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            <w:right w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            <w:insideH w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            <w:insideV w:val="none" w:sz="0" w:space="0" w:color="auto"/>\
            </w:tblBorders></w:tblPr><w:tblGrid>
            """
        for width in widths {
            xml += "<w:gridCol w:w=\"\(width)\"/>"
        }
        xml += "</w:tblGrid>"

        for row in rows {
            xml += "<w:tr>"
            for index in 0..<columnCount {
                let cell = index < row.count ? row[index] : ""
                xml += """
                    <w:tc><w:tcPr><w:tcW w:w="\(widths[index])" w:type="dxa"/></w:tcPr>\
                    \(paragraph(cell, style: nil, spacing: false))</w:tc>
                    """
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
        return xml
    }

    private static func paragraph(_ text: String, style: String?, spacing: Bool = true) -> String {
        // Table cells get tight spacing; body paragraphs keep their default.
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if !spacing { properties += "<w:spacing w:before=\"0\" w:after=\"20\"/>" }
        let styleTag = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
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
