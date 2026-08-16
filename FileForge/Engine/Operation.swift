//
//  Operation.swift
//  FileForge
//
//  The catalog: every conversion/organize/edit tool the app offers, what it
//  accepts, and what it produces. One `Operation` case per tool, grouped into
//  the categories shown in the sidebar.
//
//  Design note — why one enum rather than a class per tool:
//  ──────────────────────────────────────────────────────────────────────────
//  Every tool shares the same shape: take N input files + options, produce
//  M output files, report progress. Keeping that in one exhaustive enum means
//  the UI can be written ONCE against the whole catalog (a tool is a picker
//  value, not a screen), and adding a tool is a case plus a switch arm in the
//  runner instead of a new view. The compiler then makes an unhandled tool
//  impossible to ship.
//
//  Author: Ibrahim Sultan
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Category

/// Sidebar grouping. Mirrors the familiar layout of online PDF suites so the
/// tool you want is where you expect it.
enum OperationCategory: String, CaseIterable, Identifiable {
    case compress   = "Compress"
    case convert    = "Convert"
    case toPDF      = "Convert to PDF"
    case organize   = "Organize"
    case edit       = "Edit"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .compress: return "arrow.down.circle"
        case .convert:  return "arrow.triangle.2.circlepath"
        case .toPDF:    return "doc.badge.plus"
        case .organize: return "square.grid.2x2"
        case .edit:     return "pencil.and.outline"
        }
    }
}

// MARK: - How a tool consumes its inputs

/// Whether a tool runs once per file or once over the whole queue.
enum InputMode {
    /// Each queued file is converted independently (10 files in → 10 out).
    case perFile
    /// All queued files are consumed together to produce one output
    /// (merge: 10 files in → 1 out).
    case combined
}

// MARK: - Operation

/// One tool in the catalog.
enum Operation: String, CaseIterable, Identifiable, Hashable {

    // Compress
    case compressPDF
    case compressImage

    // Convert (from PDF)
    case pdfOCR
    case pdfToPDFA
    case pdfToImage
    case pdfToJPG
    case pdfToText
    case pdfToWord
    case pdfToExcel
    case pdfToPPT

    // Convert to PDF
    case imageToPDF
    case jpgToPDF
    case wordToPDF
    case excelToPDF
    case pptToPDF
    case odtToPDF
    case odsToPDF
    case odpToPDF
    case pagesToPDF
    case txtToPDF
    case rtfToPDF
    case htmlToPDF
    case csvToPDF
    case epubToPDF

    // Organize
    case mergePDF
    case splitPDF
    case rotatePDF
    case deletePages
    case extractPages
    case reversePages

    // Edit
    case numberPages
    case cropPDF
    case watermarkPDF
    case redactPDF
    case protectInfo

    var id: String { rawValue }

    // MARK: Presentation

    var title: String {
        switch self {
        case .compressPDF:   return "Compress PDF"
        case .compressImage: return "Compress Image"
        case .pdfOCR:        return "PDF OCR"
        case .pdfToPDFA:     return "PDF to PDF/A"
        case .pdfToImage:    return "PDF to Image (PNG)"
        case .pdfToJPG:      return "PDF to JPG"
        case .pdfToText:     return "PDF to Text"
        case .pdfToWord:     return "PDF to Word"
        case .pdfToExcel:    return "PDF to Excel"
        case .pdfToPPT:      return "PDF to PowerPoint"
        case .imageToPDF:    return "Image to PDF"
        case .jpgToPDF:      return "JPG to PDF"
        case .wordToPDF:     return "Word to PDF"
        case .excelToPDF:    return "Excel to PDF"
        case .pptToPDF:      return "PowerPoint to PDF"
        case .odtToPDF:      return "ODT to PDF"
        case .odsToPDF:      return "ODS to PDF"
        case .odpToPDF:      return "ODP to PDF"
        case .pagesToPDF:    return "Pages to PDF"
        case .txtToPDF:      return "TXT to PDF"
        case .rtfToPDF:      return "RTF to PDF"
        case .htmlToPDF:     return "HTML to PDF"
        case .csvToPDF:      return "CSV to PDF"
        case .epubToPDF:     return "EPUB to PDF"
        case .mergePDF:      return "Merge PDF"
        case .splitPDF:      return "Split PDF"
        case .rotatePDF:     return "Rotate PDF"
        case .deletePages:   return "Delete Pages"
        case .extractPages:  return "Extract Pages"
        case .reversePages:  return "Reverse Pages"
        case .numberPages:   return "Number Pages"
        case .cropPDF:       return "Crop PDF"
        case .watermarkPDF:  return "Watermark PDF"
        case .redactPDF:     return "Redact PDF"
        case .protectInfo:   return "Inspect / Unlock PDF"
        }
    }

    var subtitle: String {
        switch self {
        case .compressPDF:   return "Shrink a PDF by downsampling its images"
        case .compressImage: return "Re-encode images at a smaller size"
        case .pdfOCR:        return "Make a scanned PDF searchable with on-device OCR"
        case .pdfToPDFA:     return "Archival PDF/A-style output for long-term storage"
        case .pdfToImage:    return "One PNG per page"
        case .pdfToJPG:      return "One JPG per page"
        case .pdfToText:     return "Extract all text (OCR fallback for scans)"
        case .pdfToWord:     return "Editable .docx — needs LibreOffice"
        case .pdfToExcel:    return "Tables to .xlsx — needs LibreOffice"
        case .pdfToPPT:      return "Slides to .pptx — needs LibreOffice"
        case .imageToPDF:    return "Combine images into one PDF"
        case .jpgToPDF:      return "Combine JPGs into one PDF"
        case .wordToPDF:     return ".doc/.docx to PDF — needs LibreOffice"
        case .excelToPDF:    return ".xls/.xlsx to PDF — needs LibreOffice"
        case .pptToPDF:      return ".ppt/.pptx to PDF — needs LibreOffice"
        case .odtToPDF:      return "OpenDocument text to PDF"
        case .odsToPDF:      return "OpenDocument sheet to PDF"
        case .odpToPDF:      return "OpenDocument slides to PDF"
        case .pagesToPDF:    return "Apple Pages to PDF"
        case .txtToPDF:      return "Plain text to a paginated PDF"
        case .rtfToPDF:      return "Rich text to PDF, formatting intact"
        case .htmlToPDF:     return "Render a web page or .html file to PDF"
        case .csvToPDF:      return "Spreadsheet data as a formatted table"
        case .epubToPDF:     return "E-book to PDF"
        case .mergePDF:      return "Join every file in the queue, in order"
        case .splitPDF:      return "One PDF per page, or split at a page"
        case .rotatePDF:     return "Turn pages 90°, 180° or 270°"
        case .deletePages:   return "Remove the pages you list"
        case .extractPages:  return "Keep only the pages you list"
        case .reversePages:  return "Flip the page order"
        case .numberPages:   return "Stamp page numbers in a corner"
        case .cropPDF:       return "Trim margins by a percentage"
        case .watermarkPDF:  return "Stamp text across every page"
        case .redactPDF:     return "Permanently black out text matches"
        case .protectInfo:   return "Show metadata, or save a decrypted copy"
        }
    }

    var icon: String {
        switch self {
        case .compressPDF, .compressImage: return "arrow.down.circle.fill"
        case .pdfOCR:        return "text.viewfinder"
        case .pdfToPDFA:     return "archivebox"
        case .pdfToImage, .pdfToJPG: return "photo.on.rectangle"
        case .pdfToText:     return "doc.plaintext"
        case .pdfToWord:     return "doc.richtext"
        case .pdfToExcel:    return "tablecells"
        case .pdfToPPT:      return "rectangle.on.rectangle"
        case .imageToPDF, .jpgToPDF: return "photo.stack"
        case .wordToPDF, .odtToPDF, .pagesToPDF: return "doc.richtext.fill"
        case .excelToPDF, .odsToPDF, .csvToPDF: return "tablecells.fill"
        case .pptToPDF, .odpToPDF: return "rectangle.on.rectangle.fill"
        case .txtToPDF, .rtfToPDF: return "doc.text"
        case .htmlToPDF:     return "globe"
        case .epubToPDF:     return "book"
        case .mergePDF:      return "arrow.triangle.merge"
        case .splitPDF:      return "scissors"
        case .rotatePDF:     return "rotate.right"
        case .deletePages:   return "trash"
        case .extractPages:  return "square.and.arrow.up.on.square"
        case .reversePages:  return "arrow.up.arrow.down"
        case .numberPages:   return "list.number"
        case .cropPDF:       return "crop"
        case .watermarkPDF:  return "drop"
        case .redactPDF:     return "eye.slash"
        case .protectInfo:   return "lock.open"
        }
    }

    var category: OperationCategory {
        switch self {
        case .compressPDF, .compressImage:
            return .compress
        case .pdfOCR, .pdfToPDFA, .pdfToImage, .pdfToJPG, .pdfToText,
             .pdfToWord, .pdfToExcel, .pdfToPPT:
            return .convert
        case .imageToPDF, .jpgToPDF, .wordToPDF, .excelToPDF, .pptToPDF,
             .odtToPDF, .odsToPDF, .odpToPDF, .pagesToPDF, .txtToPDF,
             .rtfToPDF, .htmlToPDF, .csvToPDF, .epubToPDF:
            return .toPDF
        case .mergePDF, .splitPDF, .rotatePDF, .deletePages, .extractPages, .reversePages:
            return .organize
        case .numberPages, .cropPDF, .watermarkPDF, .redactPDF, .protectInfo:
            return .edit
        }
    }

    /// Merge is the one tool that consumes the whole queue at once.
    var inputMode: InputMode {
        switch self {
        case .mergePDF, .imageToPDF, .jpgToPDF: return .combined
        default: return .perFile
        }
    }

    // MARK: Input acceptance

    /// File extensions this tool accepts (lowercase, no dot). Empty means
    /// "anything" — used by the generic compressors.
    var acceptedExtensions: Set<String> {
        switch self {
        case .compressPDF, .pdfOCR, .pdfToPDFA, .pdfToImage, .pdfToJPG,
             .pdfToText, .pdfToWord, .pdfToExcel, .pdfToPPT,
             .mergePDF, .splitPDF, .rotatePDF, .deletePages, .extractPages,
             .reversePages, .numberPages, .cropPDF, .watermarkPDF,
             .redactPDF, .protectInfo:
            return ["pdf"]
        case .compressImage:
            return Self.imageExtensions
        case .imageToPDF:
            return Self.imageExtensions
        case .jpgToPDF:
            return ["jpg", "jpeg"]
        case .wordToPDF:  return ["doc", "docx"]
        case .excelToPDF: return ["xls", "xlsx"]
        case .pptToPDF:   return ["ppt", "pptx"]
        case .odtToPDF:   return ["odt"]
        case .odsToPDF:   return ["ods"]
        case .odpToPDF:   return ["odp"]
        case .pagesToPDF: return ["pages", "key", "numbers"]
        case .txtToPDF:   return ["txt", "md", "log"]
        case .rtfToPDF:   return ["rtf", "rtfd"]
        case .htmlToPDF:  return ["html", "htm", "webarchive"]
        case .csvToPDF:   return ["csv", "tsv"]
        case .epubToPDF:  return ["epub"]
        }
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
        "bmp", "gif", "webp"
    ]

    /// `true` when this file is valid input for this tool.
    func accepts(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// A human sentence for the drop zone, e.g. "Drop PDF files here".
    var acceptedDescription: String {
        let exts = acceptedExtensions.sorted().map { ".\($0)" }
        if exts.count > 4 {
            return exts.prefix(4).joined(separator: ", ") + " and more"
        }
        return exts.joined(separator: ", ")
    }

    // MARK: Requirements

    /// Tools that shell out to LibreOffice. Surfaced in the UI so a missing
    /// dependency is explained BEFORE the user queues 40 files, rather than
    /// failing 40 times afterwards.
    var needsLibreOffice: Bool {
        switch self {
        case .wordToPDF, .excelToPDF, .pptToPDF,
             .odtToPDF, .odsToPDF, .odpToPDF, .epubToPDF,
             .pdfToWord, .pdfToExcel, .pdfToPPT:
            return true
        default:
            return false
        }
    }

    /// Which options panel this tool shows.
    var optionKinds: Set<OptionKind> {
        switch self {
        case .compressPDF:   return [.imageQuality]
        case .compressImage: return [.imageQuality, .maxDimension]
        case .pdfToImage:    return [.dpi]
        case .pdfToJPG:      return [.dpi, .imageQuality]
        case .pdfOCR, .pdfToText: return [.ocrLanguage]
        case .rotatePDF:     return [.rotation, .pageRange]
        case .deletePages, .extractPages: return [.pageRange]
        case .splitPDF:      return [.splitMode]
        case .numberPages:   return [.position, .startNumber]
        case .cropPDF:       return [.cropInset]
        case .watermarkPDF:  return [.watermarkText, .opacity, .rotation]
        case .redactPDF:     return [.searchTerms]
        case .imageToPDF, .jpgToPDF: return [.pageSize]
        case .txtToPDF, .csvToPDF:   return [.pageSize, .fontSize]
        case .htmlToPDF:     return [.pageSize]
        default:             return []
        }
    }
}

// MARK: - Option kinds

/// Which controls the options panel renders for the selected tool.
enum OptionKind: Hashable {
    case imageQuality
    case maxDimension
    case dpi
    case ocrLanguage
    case rotation
    case pageRange
    case splitMode
    case position
    case startNumber
    case cropInset
    case watermarkText
    case opacity
    case searchTerms
    case pageSize
    case fontSize
}

// MARK: - Options

/// Every tunable the catalog exposes, in one struct.
///
/// A single flat struct rather than per-tool option types: the UI binds
/// directly to these fields, and a tool simply ignores what it doesn't use.
/// Defaults are chosen to be the right answer for most files, so the common
/// path is "drop files, press Convert".
struct ConversionOptions {

    /// JPEG/HEIC quality, 0…1. 0.7 is the knee of the quality/size curve —
    /// visually indistinguishable from 1.0 for most photos at a fraction of
    /// the bytes.
    var imageQuality: Double = 0.7

    /// Longest edge in pixels when downscaling; 0 = don't resize.
    var maxDimension: Double = 0

    /// Render resolution for PDF → image. 150 matches print-preview quality;
    /// 300 is true print resolution and four times the pixels.
    var dpi: Double = 150

    /// OCR language codes, Vision-style (e.g. "en-US", "es-ES").
    var ocrLanguages: [String] = ["en-US"]

    /// Clockwise rotation in degrees: 90 / 180 / 270.
    var rotation: Int = 90

    /// Page selection, 1-based, e.g. "1-3, 7, 12-". Empty = all pages.
    var pageRange: String = ""

    /// How Split PDF divides the document.
    var splitMode: SplitMode = .everyPage

    /// Where page numbers are stamped.
    var position: StampPosition = .bottomRight

    /// First page's number when numbering.
    var startNumber: Int = 1

    /// Percentage trimmed from each edge when cropping, 0…40.
    var cropInset: Double = 5

    /// Watermark text stamped across each page.
    var watermarkText: String = "CONFIDENTIAL"

    /// Watermark opacity, 0…1.
    var opacity: Double = 0.18

    /// Newline/comma-separated strings to black out when redacting.
    var searchTerms: String = ""

    /// Output page size for generated PDFs.
    var pageSize: PageSize = .usLetter

    /// Body font size for text-derived PDFs.
    var fontSize: Double = 11

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage = "Every page separately"
        case ranges    = "By the page ranges below"
        var id: String { rawValue }
    }

    enum StampPosition: String, CaseIterable, Identifiable {
        case bottomRight  = "Bottom right"
        case bottomCenter = "Bottom center"
        case bottomLeft   = "Bottom left"
        case topRight     = "Top right"
        case topCenter    = "Top center"
        case topLeft      = "Top left"
        var id: String { rawValue }
    }

    enum PageSize: String, CaseIterable, Identifiable {
        case usLetter = "US Letter"
        case a4       = "A4"
        case legal    = "Legal"
        case fitImage = "Fit to content"
        var id: String { rawValue }

        /// Size in PDF points (72 per inch).
        var points: CGSize? {
            switch self {
            case .usLetter: return CGSize(width: 612, height: 792)
            case .a4:       return CGSize(width: 595, height: 842)
            case .legal:    return CGSize(width: 612, height: 1008)
            case .fitImage: return nil
            }
        }
    }
}
