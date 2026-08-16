//
//  DocumentEngine.swift
//  FileForge
//
//  Document → PDF conversions.
//
//  Two paths, chosen per format:
//
//  1. NATIVE (TXT, RTF, HTML, CSV, Pages/Keynote/Numbers) — macOS can already
//     read these. TextKit lays out and paginates them, WebKit renders HTML,
//     and iWork documents carry a PDF preview inside the bundle. Nothing to
//     install, instant, and the output is real text (selectable, searchable).
//
//  2. LIBREOFFICE (docx/xlsx/pptx/odt/ods/odp/epub) — Apple provides no API to
//     read OOXML or OpenDocument. LibreOffice is detected at runtime rather
//     than bundled; the UI explains the one-time install instead of failing
//     mysteriously.
//
//  Author: Ibrahim Sultan
//

import Foundation
import AppKit
import PDFKit
import WebKit
import Quartz

enum DocumentEngine {

    // MARK: - Text loading

    /// Read a text file whatever encoding it happens to be in.
    ///
    /// Real-world .txt/.csv files are routinely Latin-1, UTF-16 or Windows
    /// codepage — assuming UTF-8 turns those into "couldn't open this file",
    /// which is a lie: the file is fine, our assumption wasn't. So try UTF-8,
    /// then let Foundation sniff it, then fall back to Latin-1, which decodes
    /// any byte sequence and so always succeeds as a last resort.
    static func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }

        var detected = String.Encoding.utf8
        if let sniffed = try? String(contentsOf: url, usedEncoding: &detected) { return sniffed }

        if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) { return latin1 }
        throw ForgeError.cannotOpen(url.lastPathComponent)
    }

    // MARK: - Attributed string → PDF

    /// Paginate an attributed string into a PDF using TextKit.
    ///
    /// TextKit is asked to lay the text out into page-sized containers and we
    /// draw one page per container, which is how a word processor paginates:
    /// lines never split across a page boundary and the text stays real text
    /// in the output rather than being rasterized.
    static func pdf(from attributed: NSAttributedString,
                    pageSize: CGSize,
                    margin: CGFloat = 54,
                    into url: URL) throws {
        let textSize = CGSize(width: pageSize.width - margin * 2,
                              height: pageSize.height - margin * 2)

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        // Build one container per page until every glyph is placed.
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            // Force layout for the container just added.
            _ = layout.glyphRange(for: container)
        } while layout.glyphRange(for: containers[containers.count - 1]).upperBound
            < layout.numberOfGlyphs && containers.count < 5000

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ForgeError.writeFailed(url.path)
        }

        for container in containers {
            let range = layout.glyphRange(for: container)
            // Trailing empty container — nothing left to draw.
            if range.length == 0 && container !== containers.first { continue }

            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

            // PDF's origin is bottom-left, TextKit draws top-down: flip so
            // page one starts at the top rather than off the bottom edge.
            context.saveGState()
            context.translateBy(x: margin, y: pageSize.height - margin)
            context.scaleBy(x: 1, y: -1)
            layout.drawGlyphs(forGlyphRange: range, at: .zero)
            context.restoreGState()

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: - Plain text

    static func textToPDF(_ input: URL,
                          options: ConversionOptions,
                          into folder: URL) throws -> URL {
        let text = try readText(at: input)

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(options.fontSize), weight: .regular),
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ])

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "pdf")
        try pdf(from: attributed,
                pageSize: options.pageSize.points ?? CGSize(width: 612, height: 792),
                into: out)
        return out
    }

    // MARK: - RTF

    static func rtfToPDF(_ input: URL,
                         options: ConversionOptions,
                         into folder: URL) throws -> URL {
        // RTFD is a bundle, not a file; NSAttributedString reads both but
        // needs the directory variant for .rtfd.
        let attributed: NSAttributedString
        if input.pathExtension.lowercased() == "rtfd" {
            guard let wrapper = try? FileWrapper(url: input),
                  let string = NSAttributedString(rtfdFileWrapper: wrapper,
                                                  documentAttributes: nil) else {
                throw ForgeError.cannotOpen(input.lastPathComponent)
            }
            attributed = string
        } else {
            guard let data = try? Data(contentsOf: input),
                  let string = NSAttributedString(rtf: data, documentAttributes: nil) else {
                throw ForgeError.cannotOpen(input.lastPathComponent)
            }
            attributed = string
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "pdf")
        try pdf(from: attributed,
                pageSize: options.pageSize.points ?? CGSize(width: 612, height: 792),
                into: out)
        return out
    }

    // MARK: - CSV

    /// Render delimited data as a formatted table.
    ///
    /// The parser handles the two things real CSVs always contain and naive
    /// splitters always break on: quoted fields holding the delimiter, and
    /// doubled quotes as an escaped quote.
    static func csvToPDF(_ input: URL,
                         options: ConversionOptions,
                         into folder: URL) throws -> URL {
        let raw = try readText(at: input)
        let delimiter: Character = input.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let rows = parseDelimited(raw, delimiter: delimiter)
        guard !rows.isEmpty else { throw ForgeError.nothingFound("that file has no rows") }

        // Column widths from the widest cell, so the table doesn't collapse.
        let columnCount = rows.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], min(cell.count, 40))
            }
        }

        let text = NSMutableAttributedString()
        let bodyFont = NSFont.monospacedSystemFont(ofSize: CGFloat(options.fontSize), weight: .regular)
        let headFont = NSFont.monospacedSystemFont(ofSize: CGFloat(options.fontSize), weight: .bold)

        for (index, row) in rows.enumerated() {
            let line = (0..<columnCount).map { i -> String in
                let cell = i < row.count ? row[i] : ""
                let clipped = cell.count > 40 ? String(cell.prefix(37)) + "…" : cell
                return clipped.padding(toLength: max(widths[i], clipped.count),
                                       withPad: " ", startingAt: 0)
            }.joined(separator: "  ")

            text.append(NSAttributedString(string: line + "\n", attributes: [
                .font: index == 0 ? headFont : bodyFont,
                .foregroundColor: NSColor.black
            ]))
            // Rule under the header row.
            if index == 0 {
                let rule = String(repeating: "─", count: min(line.count, 200))
                text.append(NSAttributedString(string: rule + "\n", attributes: [
                    .font: bodyFont, .foregroundColor: NSColor.darkGray
                ]))
            }
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "pdf")
        // Wide tables need landscape or they clip.
        var size = options.pageSize.points ?? CGSize(width: 612, height: 792)
        if columnCount > 6 { size = CGSize(width: size.height, height: size.width) }
        try pdf(from: text, pageSize: size, into: out)
        return out
    }

    /// RFC-4180-style parser: quoted fields, escaped quotes, embedded newlines.
    private static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let char = nextChar() {
            if inQuotes {
                if char == "\"" {
                    if let peek = iterator.next() {
                        if peek == "\"" { field.append("\"") }   // escaped quote
                        else { inQuotes = false; pending = peek }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"":
                    inQuotes = true
                case delimiter:
                    row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if !row.allSatisfy { $0.isEmpty } { rows.append(row) }
                    row = []
                default:
                    field.append(char)
                }
            }
        }
        row.append(field)
        if !row.allSatisfy { $0.isEmpty } { rows.append(row) }
        return rows
    }

    // MARK: - HTML

    /// Render an HTML file (or a URL typed into the queue) to PDF with WebKit.
    ///
    /// Runs the real browser engine, so CSS, web fonts and layout come out the
    /// way they look in Safari. `WKWebView.createPDF` needs a live view, hence
    /// the main-actor hop and the load wait.
    @MainActor
    static func htmlToPDF(_ input: URL,
                          options: ConversionOptions,
                          into folder: URL) async throws -> URL {
        let size = options.pageSize.points ?? CGSize(width: 612, height: 792)
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))

        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate

        if input.isFileURL {
            webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: input))
        }

        try await delegate.wait()
        // WebKit reports "finished" before late CSS/fonts settle; a beat here
        // is the difference between a styled page and a naked one.
        try? await Task.sleep(for: .milliseconds(600))

        let config = WKPDFConfiguration()
        let data = try await webView.pdf(configuration: config)

        let base = input.isFileURL
            ? input.deletingPathExtension().lastPathComponent
            : (input.host ?? "page")
        let out = OutputNamer.unique(in: folder, base: base, ext: "pdf")
        try data.write(to: out)
        return out
    }

    /// Bridges WKNavigationDelegate callbacks to async/await.
    @MainActor
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait() async throws {
            if finished { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                // A page that never finishes loading must not hang the queue.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(30))
                    self.finish(.success(()))
                }
            }
        }

        private func finish(_ result: Result<Void, Error>) {
            guard !finished else { return }
            finished = true
            let cont = continuation
            continuation = nil
            switch result {
            case .success: cont?.resume()
            case .failure(let error): cont?.resume(throwing: error)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(.success(()))
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(.failure(error))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finish(.failure(error))
        }
    }

    // MARK: - iWork (Pages / Keynote / Numbers)

    /// Extract the PDF preview Apple embeds inside every iWork document.
    ///
    /// iWork files are zip bundles containing `QuickLook/Preview.pdf` — a
    /// full-fidelity render Apple maintains for Quick Look. Using it means
    /// Pages → PDF works without launching Pages or needing it installed.
    /// Documents saved with "no preview" are the one case this can't handle,
    /// and the error says so.
    static func iWorkToPDF(_ input: URL, into folder: URL) throws -> URL {
        let scratch = try OutputNamer.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var preview: URL?

        // Modern iWork files are a flat zip; older ones are a real directory.
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            let candidate = input.appendingPathComponent("QuickLook/Preview.pdf")
            if FileManager.default.fileExists(atPath: candidate.path) { preview = candidate }
        } else {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-j", input.path, "QuickLook/Preview.pdf", "-d", scratch.path]
            unzip.standardOutput = Pipe()
            unzip.standardError = Pipe()
            try? unzip.run()
            unzip.waitUntilExit()
            let extracted = scratch.appendingPathComponent("Preview.pdf")
            if FileManager.default.fileExists(atPath: extracted.path) { preview = extracted }
        }

        guard let preview else {
            throw ForgeError.toolFailed(
                "iWork",
                "\(input.lastPathComponent) has no embedded preview. Open it in Pages/Keynote/Numbers and use File → Export To → PDF.")
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "pdf")
        try FileManager.default.copyItem(at: preview, to: out)
        return out
    }

    // MARK: - Office formats (LibreOffice)

    /// Convert an Office/OpenDocument/EPUB file to PDF.
    static func officeToPDF(_ input: URL, into folder: URL) throws -> URL {
        let scratch = try OutputNamer.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let produced = try LibreOffice.convert(input: input, to: "pdf", outputDirectory: scratch)
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "pdf")
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    /// Convert a PDF into an editable Office document.
    ///
    /// A caveat the UI repeats, because it's the difference between a happy
    /// user and a confused one: PDF is a layout format with no notion of
    /// paragraphs, tables or slides, so this reconstructs structure rather
    /// than recovering it. Text-based PDFs convert well; complex layouts and
    /// scans come out approximate. (Run OCR first for a scan — otherwise
    /// there's no text to convert at all.)
    static func pdfToOffice(_ input: URL,
                            filter: String,
                            ext: String,
                            into folder: URL) throws -> URL {
        let scratch = try OutputNamer.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let produced = try LibreOffice.convert(input: input, to: filter, outputDirectory: scratch)
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: ext)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }
}
