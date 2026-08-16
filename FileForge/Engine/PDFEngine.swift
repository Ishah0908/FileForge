//
//  PDFEngine.swift
//  FileForge
//
//  Every PDF-native operation: organize (merge/split/rotate/pages), edit
//  (number/crop/watermark/redact), and inspection.
//
//  All of this runs on PDFKit, which is part of macOS — no third-party PDF
//  library, no server round-trip, and nothing leaves the machine. PDFKit
//  preserves the original page content streams when reordering or copying
//  pages, so text stays selectable and vectors stay sharp; only the operations
//  that must rasterize (see ImageEngine) ever lose fidelity.
//
//  Author: Ibrahim Sultan
//

import Foundation
import PDFKit
import AppKit
import Quartz

enum PDFEngine {

    // MARK: - Loading

    /// Open a PDF, distinguishing "not a PDF" from "locked with a password" —
    /// two problems with very different fixes, which PDFKit reports the same
    /// unhelpful way (a nil or unusable document).
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw ForgeError.notAPDF(url.lastPathComponent)
        }
        if doc.isLocked {
            // An empty password unlocks a surprising number of "protected"
            // PDFs — they carry an owner password restricting printing, not a
            // user password blocking reading.
            if !doc.unlock(withPassword: "") {
                throw ForgeError.encrypted(url.lastPathComponent)
            }
        }
        guard doc.pageCount > 0 else { throw ForgeError.emptyDocument }
        return doc
    }

    private static func write(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else { throw ForgeError.writeFailed(url.path) }
    }

    // MARK: - Organize

    /// Merge every input into one PDF, in the order given (the queue order the
    /// user arranged by dragging).
    static func merge(_ inputs: [URL], into folder: URL) throws -> URL {
        guard !inputs.isEmpty else { throw ForgeError.nothingFound("no files to merge") }

        let merged = PDFDocument()
        var pageIndex = 0
        for url in inputs {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: pageIndex)
                pageIndex += 1
            }
        }
        guard merged.pageCount > 0 else { throw ForgeError.emptyDocument }

        let base = inputs.count == 1
            ? inputs[0].deletingPathExtension().lastPathComponent
            : "Merged \(inputs.count) files"
        let out = OutputNamer.unique(in: folder, base: base, ext: "pdf")
        try write(merged, to: out)
        return out
    }

    /// Split into one file per page, or into the ranges the user listed.
    static func split(_ input: URL, options: ConversionOptions, into folder: URL) throws -> [URL] {
        let doc = try open(input)
        let stem = input.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []

        switch options.splitMode {
        case .everyPage:
            // Zero-pad so 10 pages sort correctly in Finder next to page 2.
            let width = String(doc.pageCount).count
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let number = String(format: "%0\(width)d", i + 1)
                let out = OutputNamer.unique(in: folder, base: stem, suffix: " page \(number)", ext: "pdf")
                try write(single, to: out)
                outputs.append(out)
            }

        case .ranges:
            // Each comma-separated group becomes its own document, so
            // "1-3, 8-10" yields two files rather than one merged selection.
            let groups = options.pageRange
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !groups.isEmpty else { throw ForgeError.nothingFound("no page ranges given") }

            for group in groups {
                let indices = PageRange.indices(from: group, pageCount: doc.pageCount)
                guard !indices.isEmpty else { continue }
                let part = PDFDocument()
                for (slot, index) in indices.enumerated() {
                    guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
                    part.insert(page, at: slot)
                }
                guard part.pageCount > 0 else { continue }
                let label = group.replacingOccurrences(of: " ", with: "")
                let out = OutputNamer.unique(in: folder, base: stem, suffix: " pages \(label)", ext: "pdf")
                try write(part, to: out)
                outputs.append(out)
            }
        }

        guard !outputs.isEmpty else { throw ForgeError.noPagesSelected }
        return outputs
    }

    /// Rotate the selected pages clockwise. PDFKit rotation is metadata, not a
    /// re-render, so this is lossless and instant even on huge scans.
    static func rotate(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let indices = PageRange.indices(from: options.pageRange, pageCount: doc.pageCount)
        guard !indices.isEmpty else { throw ForgeError.noPagesSelected }

        for index in indices {
            guard let page = doc.page(at: index) else { continue }
            page.rotation = normalizedRotation(page.rotation + options.rotation)
        }
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " rotated", ext: "pdf")
        try write(doc, to: out)
        return out
    }

    /// PDF rotation must be a positive multiple of 90; normalize so repeated
    /// rotations don't accumulate into values PDFKit ignores.
    private static func normalizedRotation(_ degrees: Int) -> Int {
        let snapped = Int((Double(degrees) / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    /// Remove the listed pages.
    static func deletePages(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let doomed = Set(PageRange.indices(from: options.pageRange, pageCount: doc.pageCount))
        guard !doomed.isEmpty else { throw ForgeError.noPagesSelected }
        guard doomed.count < doc.pageCount else {
            throw ForgeError.nothingFound("that range is every page — the result would be empty")
        }
        // Remove from the back so earlier indices stay valid as we go.
        for index in doomed.sorted(by: >) { doc.removePage(at: index) }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " trimmed", ext: "pdf")
        try write(doc, to: out)
        return out
    }

    /// Keep only the listed pages.
    static func extractPages(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let keep = PageRange.indices(from: options.pageRange, pageCount: doc.pageCount)
        guard !keep.isEmpty else { throw ForgeError.noPagesSelected }

        let extracted = PDFDocument()
        for (slot, index) in keep.enumerated() {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
            extracted.insert(page, at: slot)
        }
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " extracted", ext: "pdf")
        try write(extracted, to: out)
        return out
    }

    /// Reverse page order — the fix for a double-sided scan fed in backwards.
    static func reversePages(_ input: URL, into folder: URL) throws -> URL {
        let doc = try open(input)
        let reversed = PDFDocument()
        for (slot, index) in stride(from: doc.pageCount - 1, through: 0, by: -1).enumerated() {
            guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
            reversed.insert(page, at: slot)
        }
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " reversed", ext: "pdf")
        try write(reversed, to: out)
        return out
    }

    // MARK: - Edit

    /// Stamp page numbers in a corner.
    ///
    /// Drawn as a PDF annotation with `.freeText`, which keeps the page's own
    /// content untouched — the number sits on top rather than being burned
    /// into a re-rendered page, so text underneath stays selectable.
    static func numberPages(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let text = "\(options.startNumber + i)"
            let box = stampRect(in: bounds, position: options.position,
                                size: CGSize(width: 60, height: 24))

            let annotation = PDFAnnotation(bounds: box, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: 11)
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = options.position.isRight ? .right
                                 : (options.position.isCenter ? .center : .left)
            // Without this PDFKit paints a 1pt border box around every number.
            annotation.border = PDFBorder()
            annotation.border?.lineWidth = 0
            page.addAnnotation(annotation)
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " numbered", ext: "pdf")
        try write(doc, to: out)
        return out
    }

    /// Trim a percentage off every edge by shrinking the crop box.
    ///
    /// Cropping a PDF is a change of visible window, not a destructive edit:
    /// the content is still there, so an over-aggressive crop is recoverable.
    static func crop(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let fraction = max(0, min(40, options.cropInset)) / 100.0

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let media = page.bounds(for: .mediaBox)
            let inset = CGRect(x: media.minX + media.width * fraction,
                               y: media.minY + media.height * fraction,
                               width: media.width * (1 - 2 * fraction),
                               height: media.height * (1 - 2 * fraction))
            page.setBounds(inset, for: .cropBox)
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " cropped", ext: "pdf")
        try write(doc, to: out)
        return out
    }

    /// Stamp translucent text diagonally across every page.
    static func watermark(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let text = options.watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ForgeError.nothingFound("watermark text is empty") }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            page.addAnnotation(WatermarkAnnotation(text: text,
                                                   angle: CGFloat(options.rotation),
                                                   opacity: CGFloat(options.opacity),
                                                   bounds: bounds))
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " watermarked", ext: "pdf")
        try write(doc, to: out)
        return out
    }

    /// Black out every occurrence of the given terms — and delete the text
    /// underneath.
    ///
    /// This is the part that makes redaction real rather than cosmetic. Drawing
    /// a black box over text leaves the words in the file, selectable and
    /// searchable, which is how redaction failures make the news. So the page
    /// is RASTERIZED after the boxes are drawn: the output page is an image,
    /// and the original text no longer exists anywhere in the document.
    ///
    /// The cost is real and worth stating: redacted pages stop being
    /// searchable and get larger. That's the correct trade for a tool whose
    /// entire job is that the words are gone.
    static func redact(_ input: URL, options: ConversionOptions, into folder: URL) throws -> URL {
        let doc = try open(input)
        let terms = options.searchTerms
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { throw ForgeError.nothingFound("no search terms given") }

        // Collect match rectangles per page first: PDFKit's selection API is
        // document-wide, and mutating pages while enumerating is asking for
        // trouble.
        var boxesByPage: [Int: [CGRect]] = [:]
        for term in terms {
            for selection in doc.findString(term, withOptions: [.caseInsensitive]) {
                for page in selection.pages {
                    let index = doc.index(for: page)
                    // Pad slightly: glyph bounds sit tight against the ink and
                    // an exact box can leave ascenders/descenders peeking out.
                    let rect = selection.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
                    boxesByPage[index, default: []].append(rect)
                }
            }
        }
        guard !boxesByPage.isEmpty else {
            throw ForgeError.nothingFound("none of those terms appear in \(input.lastPathComponent)")
        }

        let redacted = PDFDocument()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }

            guard let boxes = boxesByPage[i], !boxes.isEmpty else {
                // Untouched page: copy it as-is so it keeps its real text.
                if let copy = page.copy() as? PDFPage { redacted.insert(copy, at: redacted.pageCount) }
                continue
            }

            let flattened = try flatten(page: page, blackingOut: boxes)
            redacted.insert(flattened, at: redacted.pageCount)
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " redacted", ext: "pdf")
        try write(redacted, to: out)
        return out
    }

    /// Render one page to an image with black boxes painted over `boxes`, and
    /// return it as a new image-only PDF page. This is what destroys the
    /// underlying text.
    ///
    /// Drawn into a raw `CGContext` rather than via `NSImage.lockFocus()`:
    /// lockFocus needs a window-server connection and an AppKit run loop, so
    /// off the main thread it hands back an image backed by nothing. PDFKit
    /// then rejects it with an uncaught `NSInvalidArgumentException` and the
    /// whole app dies mid-redaction. A CGContext is thread-safe and has no
    /// such dependency.
    private static func flatten(page: PDFPage, blackingOut boxes: [CGRect]) throws -> PDFPage {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0   // 144 dpi — keeps body text readable
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())

        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ForgeError.toolFailed("Redact", "couldn't create a drawing context")
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.setFillColor(NSColor.black.cgColor)
        for box in boxes { context.fill(box) }
        context.restoreGState()

        guard let cgImage = context.makeImage() else {
            throw ForgeError.toolFailed("Redact", "couldn't rasterize the page")
        }
        let image = NSImage(cgImage: cgImage, size: bounds.size)
        guard let flattened = PDFPage(image: image) else {
            throw ForgeError.toolFailed("Redact", "couldn't rebuild the page after flattening")
        }
        flattened.setBounds(bounds, for: .mediaBox)
        return flattened
    }

    // MARK: - Inspect / unlock

    /// Report a PDF's metadata, and save a decrypted copy when the original
    /// carried only an owner password (restrictions the user can lawfully lift
    /// on their own file, e.g. a bank statement blocked from printing).
    static func inspect(_ input: URL, into folder: URL) throws -> (URL?, String) {
        guard let raw = PDFDocument(url: input) else {
            throw ForgeError.notAPDF(input.lastPathComponent)
        }
        let wasLocked = raw.isLocked
        if wasLocked, !raw.unlock(withPassword: "") {
            throw ForgeError.encrypted(input.lastPathComponent)
        }

        let attrs = raw.documentAttributes ?? [:]
        func attr(_ key: PDFDocumentAttribute) -> String {
            (attrs[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        }

        var report = """
            Pages: \(raw.pageCount)
            Title: \(attr(.titleAttribute))
            Author: \(attr(.authorAttribute))
            Created by: \(attr(.creatorAttribute))
            Encrypted: \(raw.isEncrypted ? "yes" : "no")
            Allows printing: \(raw.allowsPrinting ? "yes" : "no")
            Allows copying: \(raw.allowsCopying ? "yes" : "no")
            """

        // Only write a copy when there was actually a restriction to remove.
        guard raw.isEncrypted || !raw.allowsPrinting || !raw.allowsCopying else {
            return (nil, report + "\n\nThis PDF has no restrictions — nothing to unlock.")
        }

        let unlocked = PDFDocument()
        for i in 0..<raw.pageCount {
            guard let page = raw.page(at: i)?.copy() as? PDFPage else { continue }
            unlocked.insert(page, at: unlocked.pageCount)
        }
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " unlocked", ext: "pdf")
        try write(unlocked, to: out)
        report += "\n\nSaved an unrestricted copy."
        return (out, report)
    }

    // MARK: - Geometry helpers

    private static func stampRect(in bounds: CGRect,
                                  position: ConversionOptions.StampPosition,
                                  size: CGSize) -> CGRect {
        let margin: CGFloat = 24
        let x: CGFloat
        switch position {
        case .bottomLeft, .topLeft:     x = bounds.minX + margin
        case .bottomCenter, .topCenter: x = bounds.midX - size.width / 2
        case .bottomRight, .topRight:   x = bounds.maxX - margin - size.width
        }
        let y: CGFloat
        switch position {
        case .bottomLeft, .bottomCenter, .bottomRight: y = bounds.minY + margin
        case .topLeft, .topCenter, .topRight:          y = bounds.maxY - margin - size.height
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private extension ConversionOptions.StampPosition {
    var isRight: Bool { self == .bottomRight || self == .topRight }
    var isCenter: Bool { self == .bottomCenter || self == .topCenter }
}

// MARK: - Watermark annotation

/// A diagonal text stamp drawn across a whole page.
///
/// Subclassing `PDFAnnotation` to draw directly is the reliable way to get
/// rotated, scaled text into a PDF with PDFKit: the built-in `.freeText`
/// annotation can't rotate its content, and rasterizing the page to achieve it
/// would throw away the document's real text.
final class WatermarkAnnotation: PDFAnnotation {

    private let text: String
    private let angle: CGFloat
    private let alpha: CGFloat

    init(text: String, angle: CGFloat, opacity: CGFloat, bounds: CGRect) {
        self.text = text
        self.angle = angle
        self.alpha = max(0.02, min(1, opacity))
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let page = bounds
        // Size the text to span most of the page's diagonal, so the stamp
        // reads the same on a slide as on a legal-size scan.
        let diagonal = (page.width * page.width + page.height * page.height).squareRoot()
        var fontSize = diagonal / CGFloat(max(6, text.count)) * 1.6
        fontSize = max(18, min(fontSize, page.height * 0.4))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black.withAlphaComponent(alpha)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()

        context.saveGState()
        defer { context.restoreGState() }

        // Rotate about the page center, then draw the string centered on it.
        context.translateBy(x: page.midX, y: page.midY)
        context.rotate(by: angle * .pi / 180)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}
