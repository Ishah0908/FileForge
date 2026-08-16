//
//  OptionsPanel.swift
//  FileForge
//
//  Renders exactly the controls the selected tool uses, driven by
//  `Operation.optionKinds`. Adding a tool never means writing a settings
//  screen — declare which knobs it wants and the panel appears.
//
//  Every control carries a plain-language explanation of the trade-off it
//  makes, because the honest answer to "quality 60 or 80?" depends on what
//  the file is for and the app is the only thing here that knows what the
//  slider actually does.
//
//  Author: Ibrahim Sultan
//

import SwiftUI

struct OptionsPanel: View {
    let operation: Operation
    @Binding var options: ConversionOptions

    private var kinds: Set<OptionKind> { operation.optionKinds }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if kinds.isEmpty {
                noOptionsNote
            } else {
                Text("Options")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if kinds.contains(.imageQuality) { qualityControl }
                if kinds.contains(.maxDimension) { maxDimensionControl }
                if kinds.contains(.dpi)          { dpiControl }
                if kinds.contains(.ocrLanguage)  { languageControl }
                if kinds.contains(.splitMode)    { splitModeControl }
                if kinds.contains(.pageRange)    { pageRangeControl }
                if kinds.contains(.rotation)     { rotationControl }
                if kinds.contains(.position)     { positionControl }
                if kinds.contains(.startNumber)  { startNumberControl }
                if kinds.contains(.cropInset)    { cropControl }
                if kinds.contains(.watermarkText){ watermarkControl }
                if kinds.contains(.opacity)      { opacityControl }
                if kinds.contains(.searchTerms)  { searchTermsControl }
                if kinds.contains(.pageSize)     { pageSizeControl }
                if kinds.contains(.fontSize)     { fontSizeControl }
            }

            if let caveat = operation.caveat {
                Label(caveat, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
    }

    private var noOptionsNote: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.green)
            Text("No settings needed — drop files and convert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var qualityControl: some View {
        labeled("Quality", value: "\(Int(options.imageQuality * 100))%") {
            Slider(value: $options.imageQuality, in: 0.1...1.0)
            Text(qualityHint)
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var qualityHint: String {
        switch options.imageQuality {
        case ..<0.4:  return "Small files, visible artifacts. Fine for drafts and email."
        case ..<0.75: return "The sweet spot — big savings, hard to tell apart from the original."
        default:      return "Near-original quality. Little compression, largest files."
        }
    }

    private var maxDimensionControl: some View {
        labeled("Max width/height",
                value: options.maxDimension == 0 ? "Original" : "\(Int(options.maxDimension)) px") {
            Slider(value: $options.maxDimension, in: 0...6000, step: 100)
            Text(options.maxDimension == 0
                 ? "Not resizing — only re-encoding."
                 : "Downscales anything larger; smaller images are left alone.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var dpiControl: some View {
        labeled("Resolution", value: "\(Int(options.dpi)) DPI") {
            Slider(value: $options.dpi, in: 72...600, step: 6)
            Text(dpiHint).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dpiHint: String {
        switch options.dpi {
        case ..<100:  return "Screen-sized previews. Text may be soft."
        case ..<200:  return "Good on screen and for reference printing."
        case ..<400:  return "True print resolution — sharp, and much larger files."
        default:      return "Archival scanning quality. Very large files."
        }
    }

    private var languageControl: some View {
        labeled("OCR language", value: "") {
            Picker("", selection: Binding(
                get: { options.ocrLanguages.first ?? "en-US" },
                set: { options.ocrLanguages = [$0] }
            )) {
                Text("English").tag("en-US")
                Text("Spanish").tag("es-ES")
                Text("French").tag("fr-FR")
                Text("German").tag("de-DE")
                Text("Italian").tag("it-IT")
                Text("Portuguese").tag("pt-BR")
                Text("Chinese (Simplified)").tag("zh-Hans")
                Text("Japanese").tag("ja-JP")
                Text("Korean").tag("ko-KR")
            }
            .labelsHidden()
            Text("Recognition runs entirely on this Mac — nothing is uploaded.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var splitModeControl: some View {
        labeled("Split", value: "") {
            Picker("", selection: $options.splitMode) {
                ForEach(ConversionOptions.SplitMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        }
    }

    private var pageRangeControl: some View {
        labeled("Pages", value: "") {
            TextField("all pages", text: $options.pageRange)
                .textFieldStyle(.roundedBorder)
            Text("Examples: 1-3, 7, 12-  ·  leave empty for every page")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var rotationControl: some View {
        labeled(operation == .watermarkPDF ? "Angle" : "Rotate", value: "\(options.rotation)°") {
            if operation == .watermarkPDF {
                Slider(value: Binding(
                    get: { Double(options.rotation) },
                    set: { options.rotation = Int($0) }
                ), in: -90...90, step: 5)
            } else {
                Picker("", selection: $options.rotation) {
                    Text("90° right").tag(90)
                    Text("180°").tag(180)
                    Text("90° left").tag(270)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var positionControl: some View {
        labeled("Position", value: "") {
            Picker("", selection: $options.position) {
                ForEach(ConversionOptions.StampPosition.allCases) { spot in
                    Text(spot.rawValue).tag(spot)
                }
            }
            .labelsHidden()
        }
    }

    private var startNumberControl: some View {
        labeled("Start at", value: "") {
            Stepper(value: $options.startNumber, in: 0...9999) {
                Text("Page \(options.startNumber)").font(.callout)
            }
            Text("Useful when the document continues from another one.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var cropControl: some View {
        labeled("Trim each edge", value: "\(Int(options.cropInset))%") {
            Slider(value: $options.cropInset, in: 0...40, step: 1)
            Text("Cropping hides the margins without deleting content — it's reversible.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var watermarkControl: some View {
        labeled("Text", value: "") {
            TextField("CONFIDENTIAL", text: $options.watermarkText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var opacityControl: some View {
        labeled("Opacity", value: "\(Int(options.opacity * 100))%") {
            Slider(value: $options.opacity, in: 0.03...0.6)
            Text("Low enough to read through, high enough to be unmistakable.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchTermsControl: some View {
        labeled("Black out", value: "") {
            TextEditor(text: $options.searchTerms)
                .font(.callout)
                .frame(height: 62)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            Text("One term per line (or comma-separated). Matching is case-insensitive.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pageSizeControl: some View {
        labeled("Page size", value: "") {
            Picker("", selection: $options.pageSize) {
                ForEach(ConversionOptions.PageSize.allCases) { size in
                    Text(size.rawValue).tag(size)
                }
            }
            .labelsHidden()
        }
    }

    private var fontSizeControl: some View {
        labeled("Font size", value: "\(Int(options.fontSize)) pt") {
            Slider(value: $options.fontSize, in: 6...18, step: 0.5)
        }
    }

    // MARK: - Layout helper

    private func labeled<Content: View>(_ title: String,
                                        value: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if !value.isEmpty {
                    Text(value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }
}

// MARK: - Per-tool caveats

private extension Operation {
    /// The one thing worth knowing before running this tool. Shown in the
    /// options panel rather than buried in a help menu, because these are the
    /// facts that change whether the output is what someone expected.
    var caveat: String? {
        switch self {
        case .compressPDF:
            return "Pages become images, so text stops being selectable. Best for scans and photo-heavy PDFs."
        case .redactPDF:
            return "Matched text is removed, not just covered — those pages are flattened to images."
        case .pdfToWord:
            return "Rebuilds tables and columns as editable Word tables. Column widths are sized to fit the text, so a wide table may wrap differently than the original."
        case .pdfToExcel:
            return "Columns are inferred from how the text lines up on the page. Tabular PDFs convert well; prose becomes one column."
        case .pdfToPPT:
            return "Each page becomes a full-bleed slide image — editable as a deck, but not reverse-engineered into text boxes."
        case .pdfToPDFA:
            return "Archival-style export. Certified PDF/A-1b validation needs Ghostscript."
        case .pdfOCR:
            return "Adds an invisible text layer over the scan — the page looks identical but becomes searchable."
        case .mergePDF:
            return "Files merge in the order shown — drag rows in the queue to reorder."
        case .imageToPDF, .jpgToPDF:
            return "One image per page, in queue order."
        case .pagesToPDF:
            return "Uses the preview Apple embeds in iWork files, so Pages doesn't need to be open."
        default:
            return nil
        }
    }
}
