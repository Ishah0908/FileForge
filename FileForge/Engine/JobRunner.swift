//
//  JobRunner.swift
//  FileForge
//
//  The queue: holds the files the user dropped, runs the selected operation
//  over them, and publishes per-file progress and results to the UI.
//
//  One file failing must never stop the batch — a bad file in a queue of forty
//  marks itself failed and the rest keep converting. Everything the runner
//  does is cancellable, and heavy work stays off the main thread so the window
//  keeps responding while a hundred pages render.
//
//  Author: Ibrahim Sultan
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Queue item

/// One file in the queue, with its live status.
@MainActor
final class QueueItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL

    @Published var status: Status = .waiting
    @Published var progress: Double = 0
    /// Files produced from this input.
    @Published var outputs: [URL] = []
    /// A short note shown under the row: savings, OCR word count, caveats.
    @Published var note: String = ""

    let byteSize: Int64

    init(url: URL) {
        self.url = url
        self.byteSize = Format.fileSize(of: url)
    }

    enum Status: Equatable {
        case waiting
        case running
        case done
        case failed(String)
        case skipped(String)

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .skipped: return true
            case .waiting, .running: return false
            }
        }
    }

    var name: String { url.lastPathComponent }
    var sizeText: String { Format.bytes(byteSize) }
}

// MARK: - Runner

@MainActor
final class JobRunner: ObservableObject {

    // MARK: Published state

    /// The queue, in the order it will be processed (drag to reorder).
    @Published var items: [QueueItem] = []

    /// The tool the sidebar has selected.
    @Published var operation: Operation = .mergePDF {
        didSet { if operation != oldValue { revalidateQueue() } }
    }

    /// Live-bound tool options.
    @Published var options = ConversionOptions()

    /// Where results are written. Defaults to a Finder-visible folder rather
    /// than somewhere the user has to go hunting for.
    @Published var outputFolder: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = downloads.appendingPathComponent("FileForge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    @Published private(set) var isRunning = false
    @Published private(set) var overallProgress: Double = 0
    @Published var statusLine = ""

    /// Everything produced by the last run, for the results panel.
    @Published private(set) var producedFiles: [URL] = []

    private var task: Task<Void, Never>?

    // MARK: Derived

    /// Queue entries the current tool can actually process.
    var eligibleItems: [QueueItem] {
        items.filter { operation.accepts($0.url) }
    }

    /// Entries that will be skipped because the tool doesn't take them.
    var ineligibleCount: Int { items.count - eligibleItems.count }

    var canRun: Bool {
        !isRunning && !eligibleItems.isEmpty && !(operation.needsLibreOffice && !LibreOffice.isInstalled)
    }

    // MARK: - Queue management

    /// Add files, ignoring duplicates and expanding any folders dropped in.
    func add(urls: [URL]) {
        var discovered: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            // A dropped folder means "everything in here" — but iWork bundles
            // are directories too, and must be treated as single documents.
            if isDirectory.boolValue && !Self.bundleExtensions.contains(url.pathExtension.lowercased()) {
                let enumerated = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let child = enumerated?.nextObject() as? URL {
                    var childIsDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: child.path, isDirectory: &childIsDir)
                    if !childIsDir.boolValue || Self.bundleExtensions.contains(child.pathExtension.lowercased()) {
                        discovered.append(child)
                    }
                }
            } else {
                discovered.append(url)
            }
        }

        let existing = Set(items.map(\.url.standardizedFileURL))
        let fresh = discovered
            .map(\.standardizedFileURL)
            .filter { !existing.contains($0) }

        items.append(contentsOf: fresh.map { QueueItem(url: $0) })
        revalidateQueue()
    }

    private static let bundleExtensions: Set<String> = ["pages", "key", "numbers", "rtfd"]

    func remove(_ item: QueueItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearQueue() {
        guard !isRunning else { return }
        items.removeAll()
        producedFiles = []
        statusLine = ""
        overallProgress = 0
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Reset statuses when the tool changes: entries the new tool can't take
    /// are marked skipped up front, so the queue tells the truth before the
    /// user presses Convert rather than after.
    private func revalidateQueue() {
        for item in items {
            if operation.accepts(item.url) {
                item.status = .waiting
                item.note = ""
                item.progress = 0
                item.outputs = []
            } else {
                item.status = .skipped("\(operation.title) doesn't take .\(item.url.pathExtension.lowercased()) files")
            }
        }
        producedFiles = []
    }

    // MARK: - Running

    func run() {
        guard canRun else { return }
        let targets = eligibleItems
        let op = operation
        let opts = options
        let folder = outputFolder

        // Make sure the destination exists — the user may have deleted or
        // renamed it since it was chosen.
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            statusLine = "Can't write to \(folder.lastPathComponent): \(error.localizedDescription)"
            return
        }

        isRunning = true
        overallProgress = 0
        producedFiles = []
        statusLine = "Converting…"
        for item in targets {
            item.status = .waiting
            item.progress = 0
            item.outputs = []
            item.note = ""
        }

        task = Task { [weak self] in
            guard let self else { return }
            await self.execute(operation: op, options: opts, targets: targets, folder: folder)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        statusLine = "Cancelled."
        for item in items where item.status == .running {
            item.status = .failed("Cancelled")
        }
    }

    // MARK: - Execution

    private func execute(operation op: Operation,
                         options opts: ConversionOptions,
                         targets: [QueueItem],
                         folder: URL) async {
        var produced: [URL] = []

        if op.inputMode == .combined {
            // One job over the whole queue (merge, images → PDF).
            for item in targets { item.status = .running }
            do {
                let inputs = targets.map(\.url)
                let outputs = try await runCombined(op: op, inputs: inputs, options: opts, folder: folder) { fraction in
                    Task { @MainActor in
                        self.overallProgress = fraction
                        for item in targets { item.progress = fraction }
                    }
                }
                produced = outputs
                for item in targets {
                    item.status = .done
                    item.progress = 1
                    item.outputs = outputs
                }
                statusLine = "Created \(outputs.first?.lastPathComponent ?? "output") from \(targets.count) files."
            } catch is CancellationError {
                statusLine = "Cancelled."
            } catch {
                for item in targets { item.status = .failed(error.localizedDescription) }
                statusLine = error.localizedDescription
            }
            overallProgress = 1

        } else {
            // One job per file; a failure marks that row and the batch goes on.
            var completed = 0
            var failures = 0

            for item in targets {
                if Task.isCancelled { break }
                item.status = .running

                do {
                    let (outputs, note) = try await runSingle(
                        op: op, input: item.url, options: opts, folder: folder
                    ) { fraction in
                        Task { @MainActor in item.progress = fraction }
                    }
                    item.outputs = outputs
                    item.note = note
                    item.progress = 1
                    item.status = .done
                    produced.append(contentsOf: outputs)
                } catch is CancellationError {
                    item.status = .failed("Cancelled")
                    break
                } catch {
                    failures += 1
                    item.status = .failed(error.localizedDescription)
                }

                completed += 1
                overallProgress = Double(completed) / Double(targets.count)
            }

            let succeeded = completed - failures
            statusLine = failures == 0
                ? "Finished — \(succeeded) file\(succeeded == 1 ? "" : "s") converted, \(produced.count) file\(produced.count == 1 ? "" : "s") created."
                : "Finished — \(succeeded) converted, \(failures) failed. Hover a failed row for the reason."
        }

        producedFiles = produced
        isRunning = false
        task = nil
    }

    /// Tools that consume the whole queue at once.
    private func runCombined(op: Operation,
                             inputs: [URL],
                             options: ConversionOptions,
                             folder: URL,
                             progress: @escaping (Double) -> Void) async throws -> [URL] {
        switch op {
        case .mergePDF:
            return try await Task.detached(priority: .userInitiated) {
                [try PDFEngine.merge(inputs, into: folder)]
            }.value

        case .imageToPDF, .jpgToPDF:
            return try await Task.detached(priority: .userInitiated) {
                [try ImageEngine.imagesToPDF(inputs, options: options, into: folder, progress: progress)]
            }.value

        default:
            throw ForgeError.unsupported(op.title)
        }
    }

    /// Tools that run per file. Returns the outputs and an optional note.
    private func runSingle(op: Operation,
                           input: URL,
                           options: ConversionOptions,
                           folder: URL,
                           progress: @escaping (Double) -> Void) async throws -> ([URL], String) {
        switch op {

        // ── Compress ───────────────────────────────────────────────────────
        case .compressPDF:
            return try await detached {
                let (url, note) = try ImageEngine.compressPDF(input, options: options,
                                                              into: folder, progress: progress)
                return ([url], note)
            }

        case .compressImage:
            return try await detached {
                let (url, note) = try ImageEngine.compressImage(input, options: options, into: folder)
                return ([url], note)
            }

        // ── Convert from PDF ───────────────────────────────────────────────
        case .pdfToImage:
            return try await detached {
                (try ImageEngine.pdfToImages(input, format: .png, options: options,
                                             into: folder, progress: progress), "")
            }

        case .pdfToJPG:
            return try await detached {
                (try ImageEngine.pdfToImages(input, format: .jpeg, options: options,
                                             into: folder, progress: progress), "")
            }

        case .pdfToText:
            return try await detached {
                let (url, note) = try ImageEngine.pdfToText(input, options: options,
                                                            into: folder, progress: progress)
                return ([url], note)
            }

        case .pdfOCR:
            return try await detached {
                let (url, note) = try ImageEngine.ocrPDF(input, options: options,
                                                         into: folder, progress: progress)
                return ([url], note)
            }

        case .pdfToPDFA:
            return try await detached {
                let (url, note) = try ImageEngine.pdfToPDFA(input, into: folder)
                return ([url], note)
            }

        case .pdfToWord:
            return try await detached {
                ([try DocumentEngine.pdfToOffice(input, filter: "docx:MS Word 2007 XML",
                                                 ext: "docx", into: folder)],
                 "Layout is reconstructed, not recovered — check formatting.")
            }

        case .pdfToExcel:
            return try await detached {
                ([try DocumentEngine.pdfToOffice(input, filter: "xlsx:Calc MS Excel 2007 XML",
                                                 ext: "xlsx", into: folder)],
                 "Tables are inferred from layout — verify the cells.")
            }

        case .pdfToPPT:
            return try await detached {
                ([try DocumentEngine.pdfToOffice(input, filter: "pptx:Impress MS PowerPoint 2007 XML",
                                                 ext: "pptx", into: folder)],
                 "Each page becomes a slide image where layout can't be parsed.")
            }

        // ── Convert to PDF ─────────────────────────────────────────────────
        case .txtToPDF:
            return try await detached { ([try DocumentEngine.textToPDF(input, options: options, into: folder)], "") }

        case .rtfToPDF:
            return try await detached { ([try DocumentEngine.rtfToPDF(input, options: options, into: folder)], "") }

        case .csvToPDF:
            return try await detached { ([try DocumentEngine.csvToPDF(input, options: options, into: folder)], "") }

        case .htmlToPDF:
            // WebKit must run on the main actor — no detached hop here.
            let url = try await DocumentEngine.htmlToPDF(input, options: options, into: folder)
            return ([url], "")

        case .pagesToPDF:
            return try await detached { ([try DocumentEngine.iWorkToPDF(input, into: folder)], "") }

        case .wordToPDF, .excelToPDF, .pptToPDF,
             .odtToPDF, .odsToPDF, .odpToPDF, .epubToPDF:
            return try await detached { ([try DocumentEngine.officeToPDF(input, into: folder)], "") }

        // ── Organize ───────────────────────────────────────────────────────
        case .splitPDF:
            return try await detached { (try PDFEngine.split(input, options: options, into: folder), "") }

        case .rotatePDF:
            return try await detached { ([try PDFEngine.rotate(input, options: options, into: folder)], "") }

        case .deletePages:
            return try await detached { ([try PDFEngine.deletePages(input, options: options, into: folder)], "") }

        case .extractPages:
            return try await detached { ([try PDFEngine.extractPages(input, options: options, into: folder)], "") }

        case .reversePages:
            return try await detached { ([try PDFEngine.reversePages(input, into: folder)], "") }

        // ── Edit ───────────────────────────────────────────────────────────
        case .numberPages:
            return try await detached { ([try PDFEngine.numberPages(input, options: options, into: folder)], "") }

        case .cropPDF:
            return try await detached { ([try PDFEngine.crop(input, options: options, into: folder)], "") }

        case .watermarkPDF:
            return try await detached { ([try PDFEngine.watermark(input, options: options, into: folder)], "") }

        case .redactPDF:
            return try await detached {
                ([try PDFEngine.redact(input, options: options, into: folder)],
                 "Redacted pages were flattened to images so the text is truly gone.")
            }

        case .protectInfo:
            return try await detached {
                let (url, report) = try PDFEngine.inspect(input, into: folder)
                return (url.map { [$0] } ?? [], report)
            }

        // Combined-mode tools never reach here.
        case .mergePDF, .imageToPDF, .jpgToPDF:
            throw ForgeError.unsupported(op.title)
        }
    }

    /// Run blocking work off the main actor, honoring cancellation.
    private func detached<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try body()
        }.value
    }

    // MARK: - Finder helpers

    func revealOutputs() {
        guard !producedFiles.isEmpty else {
            NSWorkspace.shared.activateFileViewerSelecting([outputFolder])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(producedFiles)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where FileForge saves results"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func addFilesViaPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add files to convert"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }
}
