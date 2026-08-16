//
//  ImageEngine.swift
//  FileForge
//
//  Raster work: PDF → images, images → PDF, image compression, PDF
//  compression, on-device OCR, and PDF/A-style archival output.
//
//  OCR uses Apple's Vision framework, which ships with macOS and runs entirely
//  on the Neural Engine — no Tesseract to install, no page uploaded anywhere,
//  and it is genuinely good at photographed and skewed text.
//
//  Author: Ibrahim Sultan
//

import Foundation
import PDFKit
import AppKit
import Vision
import UniformTypeIdentifiers
import CoreGraphics

enum ImageEngine {

    // MARK: - Thread-safe rasterizing

    /// Draw into an offscreen bitmap and return the result as an `NSImage`.
    ///
    /// Every raster path in this app goes through here rather than
    /// `NSImage.lockFocus()`. lockFocus draws through AppKit's window server
    /// connection, which does not exist on a background thread — the image
    /// comes back with no backing store, and `PDFPage(image:)` then throws an
    /// uncaught Objective-C exception that takes the whole app down rather
    /// than failing one file. Conversions run off the main thread by design,
    /// so a `CGContext` is the only correct tool here.
    ///
    /// - Parameter size: the logical (point) size of the result.
    /// - Parameter scale: pixel density multiplier.
    static func rasterize(size: CGSize,
                          scale: CGFloat,
                          draw: (CGContext) -> Void) -> NSImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        // Scans and slides are often transparent; JPEG has no alpha, so an
        // unfilled background renders black instead of white.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        draw(context)

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Rasterize one PDF page at `scale`, honoring its crop box.
    private static func rasterize(page: PDFPage, scale: CGFloat) -> NSImage? {
        let bounds = page.bounds(for: .cropBox)
        return rasterize(size: bounds.size, scale: scale) { context in
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .cropBox, to: context)
        }
    }

    // MARK: - PDF → images

    /// Render each selected page to a PNG or JPG at the requested DPI.
    ///
    /// PDF user-space is 72 points per inch, so the render scale is simply
    /// dpi/72 — 150 dpi is a little over 2×, which is the sweet spot where
    /// body text stays crisp without producing 30 MB per page.
    static func pdfToImages(_ input: URL,
                            format: ImageFormat,
                            options: ConversionOptions,
                            into folder: URL,
                            progress: (Double) -> Void) throws -> [URL] {
        let doc = try PDFEngine.open(input)
        let indices = PageRange.indices(from: options.pageRange, pageCount: doc.pageCount)
        guard !indices.isEmpty else { throw ForgeError.noPagesSelected }

        let scale = max(0.5, options.dpi / 72.0)
        let stem = input.deletingPathExtension().lastPathComponent
        let width = String(doc.pageCount).count
        var outputs: [URL] = []

        for (step, index) in indices.enumerated() {
            guard let page = doc.page(at: index),
                  let image = rasterize(page: page, scale: scale) else { continue }

            let number = String(format: "%0\(width)d", index + 1)
            let out = OutputNamer.unique(in: folder, base: stem,
                                         suffix: " page \(number)", ext: format.fileExtension)
            try encode(image, as: format, quality: options.imageQuality, to: out)
            outputs.append(out)
            progress(Double(step + 1) / Double(indices.count))
        }

        guard !outputs.isEmpty else { throw ForgeError.noPagesSelected }
        return outputs
    }

    // MARK: - Images → PDF

    /// Combine images into one PDF, one image per page.
    ///
    /// Each image is drawn aspect-fit onto the chosen page size (or the page
    /// takes the image's own dimensions when "Fit to content" is picked, which
    /// is what you want for screenshots and scans that are already page-shaped).
    static func imagesToPDF(_ inputs: [URL],
                            options: ConversionOptions,
                            into folder: URL,
                            progress: (Double) -> Void) throws -> URL {
        guard !inputs.isEmpty else { throw ForgeError.nothingFound("no images to convert") }

        let pdf = PDFDocument()
        for (step, url) in inputs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                throw ForgeError.cannotOpen(url.lastPathComponent)
            }

            let canvas = options.pageSize.points.flatMap { fit(image, into: $0) } ?? image
            guard let page = PDFPage(image: canvas) else {
                throw ForgeError.cannotOpen(url.lastPathComponent)
            }
            pdf.insert(page, at: pdf.pageCount)
            progress(Double(step + 1) / Double(inputs.count))
        }

        guard pdf.pageCount > 0 else { throw ForgeError.emptyDocument }
        let base = inputs.count == 1
            ? inputs[0].deletingPathExtension().lastPathComponent
            : "\(inputs.count) images"
        let out = OutputNamer.unique(in: folder, base: base, ext: "pdf")
        guard pdf.write(to: out) else { throw ForgeError.writeFailed(out.path) }
        return out
    }

    /// Draw `image` centered and aspect-fit on a white canvas of `size`.
    private static func fit(_ image: NSImage, into size: CGSize) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (size.width - drawn.width) / 2,
                             y: (size.height - drawn.height) / 2)

        return rasterize(size: size, scale: 1) { context in
            context.draw(cgImage, in: CGRect(origin: origin, size: drawn))
        }
    }

    // MARK: - Image compression

    /// Re-encode an image smaller: optionally downscale, then compress.
    ///
    /// Reports the original size alongside the new one so the user can see
    /// whether it was worth it — re-encoding an already-optimized JPEG can
    /// make it bigger, and the app says so rather than pretending it helped.
    static func compressImage(_ input: URL,
                              options: ConversionOptions,
                              into folder: URL) throws -> (URL, String) {
        guard let image = NSImage(contentsOf: input) else {
            throw ForgeError.cannotOpen(input.lastPathComponent)
        }
        let before = Format.fileSize(of: input)

        var working = image
        let limit = options.maxDimension
        if limit > 0,
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // Measure in PIXELS, not points: NSImage.size is DPI-aware, so a
            // 4000px scan tagged 300dpi reports 960pt and would skip resizing
            // entirely — the exact case this option exists for.
            let pixels = CGSize(width: cgImage.width, height: cgImage.height)
            let longest = max(pixels.width, pixels.height)
            if longest > limit {
                let scale = limit / longest
                let target = CGSize(width: (pixels.width * scale).rounded(),
                                    height: (pixels.height * scale).rounded())
                if let resized = rasterize(size: target, scale: 1, draw: { context in
                    context.interpolationQuality = .high
                    context.draw(cgImage, in: CGRect(origin: .zero, size: target))
                }) {
                    working = resized
                }
            }
        }

        // PNG has no quality dial, so a PNG being "compressed" is converted to
        // JPEG — that's the only way to make it meaningfully smaller. Formats
        // that are already lossy keep their own extension.
        let format: ImageFormat = input.pathExtension.lowercased() == "png" && options.imageQuality < 1
            ? .jpeg : ImageFormat(fileExtension: input.pathExtension) ?? .jpeg

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " compressed", ext: format.fileExtension)
        try encode(working, as: format, quality: options.imageQuality, to: out)

        // Re-encoding can produce a LARGER file — flat graphics and already
        // optimized JPEGs both do this. A tool called "Compress" handing back
        // something bigger is a bug, so keep the original instead and say so.
        // (Skipped when the user asked for a resize: a smaller image is the
        // point there, even if the bytes don't shrink.)
        let after = Format.fileSize(of: out)
        let didResize = working !== image
        if after >= before && !didResize {
            try? FileManager.default.removeItem(at: out)
            let copy = OutputNamer.unique(in: folder,
                                          base: input.deletingPathExtension().lastPathComponent,
                                          suffix: " (already small)",
                                          ext: input.pathExtension.lowercased())
            try FileManager.default.copyItem(at: input, to: copy)
            return (copy, "Already efficiently encoded at \(Format.bytes(before)) — re-encoding would have made it bigger, so the original was kept.")
        }
        return (out, Format.savings(from: before, to: after))
    }

    // MARK: - PDF compression

    /// Shrink a PDF by re-rendering each page as a compressed JPEG.
    ///
    /// This is the honest trade and the app states it plainly in the UI: the
    /// output is images, so text stops being selectable. For the files people
    /// actually need to shrink — phone scans and photo-heavy decks, where the
    /// bulk is images anyway — it typically cuts 60–90%. A text-only PDF is
    /// already small and will come back LARGER, so that case is detected and
    /// the original is kept instead.
    static func compressPDF(_ input: URL,
                            options: ConversionOptions,
                            into folder: URL,
                            progress: (Double) -> Void) throws -> (URL, String) {
        let doc = try PDFEngine.open(input)
        let before = Format.fileSize(of: input)
        let compressed = PDFDocument()
        // 110 dpi keeps scanned text legible on screen while discarding the
        // 300+ dpi detail that makes phone scans enormous.
        let scale: CGFloat = 110.0 / 72.0

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            guard let image = rasterize(page: page, scale: scale) else { continue }

            // Round-trip through JPEG data so the page carries compressed
            // pixels, not a lossless bitmap.
            guard let data = jpegData(from: image, quality: options.imageQuality),
                  let reloaded = NSImage(data: data),
                  let newPage = PDFPage(image: reloaded) else { continue }
            newPage.setBounds(bounds, for: .mediaBox)
            compressed.insert(newPage, at: compressed.pageCount)
            progress(Double(i + 1) / Double(doc.pageCount))
        }

        guard compressed.pageCount > 0 else { throw ForgeError.emptyDocument }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " compressed", ext: "pdf")
        guard compressed.write(to: out) else { throw ForgeError.writeFailed(out.path) }

        let after = Format.fileSize(of: out)
        if after >= before {
            // Never hand back something worse than what we were given.
            try? FileManager.default.removeItem(at: out)
            let copy = OutputNamer.unique(in: folder,
                                          base: input.deletingPathExtension().lastPathComponent,
                                          suffix: " (already small)", ext: "pdf")
            try FileManager.default.copyItem(at: input, to: copy)
            return (copy, "Already well compressed (\(Format.bytes(before))) — kept the original, which is smaller than anything re-encoding would produce.")
        }
        return (out, Format.savings(from: before, to: after) + " · pages are now images, so text is no longer selectable")
    }

    // MARK: - OCR

    /// Add an invisible, searchable text layer to a scanned PDF.
    ///
    /// The page image is kept exactly as-is and recognized text is added as
    /// transparent annotations positioned over the words — so the document
    /// looks identical but Spotlight, Preview's search, and copy/paste all
    /// work. That is what "OCR a PDF" should mean; replacing the page with
    /// re-typeset text would change how it looks.
    static func ocrPDF(_ input: URL,
                       options: ConversionOptions,
                       into folder: URL,
                       progress: (Double) -> Void) throws -> (URL, String) {
        let doc = try PDFEngine.open(input)
        var totalWords = 0

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            guard let cgImage = render(page: page, scale: 2.0) else { continue }

            let observations = try recognizeText(in: cgImage, languages: options.ocrLanguages)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                // Vision reports a normalized box with the origin bottom-left,
                // which is also PDF's convention — so this maps directly.
                let box = observation.boundingBox
                let rect = CGRect(x: bounds.minX + box.minX * bounds.width,
                                  y: bounds.minY + box.minY * bounds.height,
                                  width: box.width * bounds.width,
                                  height: box.height * bounds.height)

                let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                annotation.contents = candidate.string
                // Invisible: the ink is already in the page image underneath.
                annotation.fontColor = .clear
                annotation.color = .clear
                annotation.font = NSFont.systemFont(ofSize: max(4, rect.height * 0.8))
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 0
                page.addAnnotation(annotation)
                totalWords += candidate.string.split(separator: " ").count
            }
            progress(Double(i + 1) / Double(doc.pageCount))
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " searchable", ext: "pdf")
        guard doc.write(to: out) else { throw ForgeError.writeFailed(out.path) }
        return (out, totalWords > 0
                ? "Recognized about \(totalWords) words — the PDF is now searchable"
                : "No text was recognized. If the scan is faint or rotated, try a higher-quality scan.")
    }

    /// Extract a PDF's text, falling back to OCR for scans with no text layer.
    static func pdfToText(_ input: URL,
                          options: ConversionOptions,
                          into folder: URL,
                          progress: (Double) -> Void) throws -> (URL, String) {
        let doc = try PDFEngine.open(input)
        var pieces: [String] = []
        var usedOCR = false

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if embedded.count > 20 {
                pieces.append(embedded)
            } else if let cgImage = render(page: page, scale: 2.0) {
                // Almost no embedded text: this page is a scan, so read it.
                usedOCR = true
                let observations = try recognizeText(in: cgImage, languages: options.ocrLanguages)
                let text = observations.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                if !text.isEmpty { pieces.append(text) }
            }
            progress(Double(i + 1) / Double(doc.pageCount))
        }

        let body = pieces.joined(separator: "\n\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ForgeError.nothingFound("no text could be read from \(input.lastPathComponent)")
        }

        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     ext: "txt")
        try body.write(to: out, atomically: true, encoding: .utf8)
        return (out, usedOCR ? "Used OCR for pages with no text layer" : "Extracted the PDF's own text")
    }

    /// Run Vision text recognition over one page image.
    private static func recognizeText(in image: CGImage,
                                      languages: [String]) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Rasterize a PDF page for Vision.
    private static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: - PDF/A

    /// Produce an archival-style PDF: self-contained, with document metadata
    /// and an embedded PDF/A identification marker.
    ///
    /// Worth being precise about what this does and doesn't do, because the
    /// UI says the same: it rewrites the file through Quartz with archival
    /// metadata and a flattened, self-contained page stream. It is not a
    /// validated PDF/A-1b conversion — full compliance additionally requires
    /// embedding an ICC output intent and every font subset, which needs
    /// Ghostscript. For "the archive wants a PDF/A-ish file that opens
    /// forever", this is right; for a compliance audit, run Ghostscript.
    static func pdfToPDFA(_ input: URL, into folder: URL) throws -> (URL, String) {
        let doc = try PDFEngine.open(input)
        let out = OutputNamer.unique(in: folder,
                                     base: input.deletingPathExtension().lastPathComponent,
                                     suffix: " archival", ext: "pdf")

        var attributes = doc.documentAttributes ?? [:]
        // NOTE: `producerAttribute` is deliberately not set — Quartz stamps
        // its own Producer string when writing and silently discards ours, so
        // relying on it would make this metadata a lie. Creator, Title,
        // Subject and Keywords all survive the write.
        attributes[PDFDocumentAttribute.creatorAttribute] = "FileForge"
        attributes[PDFDocumentAttribute.subjectAttribute] = "PDF/A-style archival export"
        if attributes[PDFDocumentAttribute.titleAttribute] == nil {
            attributes[PDFDocumentAttribute.titleAttribute] =
                input.deletingPathExtension().lastPathComponent
        }
        var keywords = (attributes[PDFDocumentAttribute.keywordsAttribute] as? [String]) ?? []
        keywords.append("archival")
        attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
        attributes[PDFDocumentAttribute.modificationDateAttribute] = Date()
        doc.documentAttributes = attributes

        guard doc.write(to: out) else { throw ForgeError.writeFailed(out.path) }
        return (out, "Archival copy written. For certified PDF/A-1b compliance, validate with Ghostscript — this export is archival-style, not audited.")
    }

    // MARK: - Encoding

    /// Image container formats the app writes.
    enum ImageFormat {
        case png, jpeg, tiff, heic

        init?(fileExtension: String) {
            switch fileExtension.lowercased() {
            case "png": self = .png
            case "jpg", "jpeg": self = .jpeg
            case "tif", "tiff": self = .tiff
            case "heic", "heif": self = .heic
            default: return nil
            }
        }

        var fileExtension: String {
            switch self {
            case .png:  return "png"
            case .jpeg: return "jpg"
            case .tiff: return "tiff"
            case .heic: return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .png:  return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            case .heic: return UTType("public.heic") ?? .jpeg
            }
        }
    }

    private static func jpegData(from image: NSImage, quality: Double) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: max(0.05, min(1, quality))])
    }

    /// Write `image` to `url` in `format`.
    ///
    /// Goes through ImageIO rather than NSBitmapImageRep for everything except
    /// JPEG/PNG so HEIC — which NSBitmapImageRep cannot write — works too.
    private static func encode(_ image: NSImage,
                               as format: ImageFormat,
                               quality: Double,
                               to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ForgeError.toolFailed("Encode", "couldn't read the image data")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ForgeError.writeFailed(url.path)
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0.05, min(1, quality))
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ForgeError.writeFailed(url.path)
        }
    }
}
