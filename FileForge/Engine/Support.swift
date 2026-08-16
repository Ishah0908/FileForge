//
//  Support.swift
//  FileForge
//
//  Shared plumbing every converter needs: page-range parsing, non-clobbering
//  output naming, byte formatting, and locating LibreOffice.
//
//  Author: Ibrahim Sultan
//

import Foundation
import AppKit

// MARK: - Errors

/// Failures a conversion can report. Each message is written to be read by the
/// person who dropped the file, not by a developer — it says what to do next.
enum ForgeError: LocalizedError {
    case cannotOpen(String)
    case notAPDF(String)
    case emptyDocument
    case noPagesSelected
    case libreOfficeMissing
    case toolFailed(String, String)
    case unsupported(String)
    case encrypted(String)
    case writeFailed(String)
    case nothingFound(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name):
            return "Couldn't open \(name). The file may be corrupt or in a format macOS doesn't recognize."
        case .notAPDF(let name):
            return "\(name) isn't a readable PDF."
        case .emptyDocument:
            return "That document has no pages."
        case .noPagesSelected:
            return "The page range didn't match any pages in this document."
        case .libreOfficeMissing:
            return "This conversion needs LibreOffice, which isn't installed. Install it free from libreoffice.org (or run: brew install --cask libreoffice), then try again."
        case .toolFailed(let tool, let detail):
            return "\(tool) failed: \(detail)"
        case .unsupported(let what):
            return "Not supported: \(what)"
        case .encrypted(let name):
            return "\(name) is password-protected. Open it in Preview with the password and save a copy, then convert that."
        case .writeFailed(let path):
            return "Couldn't write to \(path). Check the folder still exists and isn't read-only."
        case .nothingFound(let what):
            return "Nothing to do: \(what)"
        }
    }
}

// MARK: - Page ranges

/// Parses the page-range syntax used throughout the app: `1-3, 7, 12-`.
///
/// Deliberately forgiving — this is typed by hand under time pressure, so
/// spaces, trailing commas, reversed ranges (`7-3`) and out-of-bounds numbers
/// are all tolerated rather than rejected. Anything genuinely unparseable is
/// skipped instead of failing the whole job.
enum PageRange {

    /// Zero-based page indices selected by `spec` from a `pageCount`-page
    /// document, in ascending order with duplicates removed.
    ///
    /// An empty or whitespace-only spec means EVERY page — the common case,
    /// where the user left the field alone.
    static func indices(from spec: String, pageCount: Int) -> [Int] {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Array(0..<pageCount) }

        var selected = Set<Int>()
        for chunk in trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }

            if let dash = part.firstIndex(where: { $0 == "-" || $0 == "\u{2013}" }) {
                let lhs = part[part.startIndex..<dash].trimmingCharacters(in: .whitespaces)
                let rhs = part[part.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                // "12-" means 12 to the end; "-5" means 1 through 5.
                let start = Int(lhs) ?? 1
                let end = Int(rhs) ?? pageCount
                let (lo, hi) = start <= end ? (start, end) : (end, start)
                for page in max(1, lo)...max(1, hi) where page <= pageCount {
                    selected.insert(page - 1)
                }
            } else if let page = Int(part), page >= 1, page <= pageCount {
                selected.insert(page - 1)
            }
        }
        return selected.sorted()
    }
}

// MARK: - Output naming

/// Builds destination URLs that never silently overwrite an existing file.
enum OutputNamer {

    /// `<folder>/<base><suffix>.<ext>`, with ` 2`, ` 3`… appended if that name
    /// is taken. Overwriting a file the user already has is the one mistake a
    /// batch converter must never make.
    static func unique(in folder: URL,
                       base: String,
                       suffix: String = "",
                       ext: String) -> URL {
        let cleanBase = base.isEmpty ? "Untitled" : base
        var candidate = folder.appendingPathComponent("\(cleanBase)\(suffix).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(cleanBase)\(suffix) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// A scratch directory for intermediate files, cleaned up by the caller.
    static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileForge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Formatting

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func bytes(_ count: Int64) -> String {
        byteFormatter.string(fromByteCount: count)
    }

    static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
    }

    /// "2.4 MB → 810 KB (66% smaller)" — the sentence a compressor should say.
    static func savings(from before: Int64, to after: Int64) -> String {
        guard before > 0, after > 0 else { return bytes(after) }
        let delta = Double(before - after) / Double(before) * 100
        if delta > 0.5 {
            return "\(bytes(before)) → \(bytes(after)) (\(Int(delta.rounded()))% smaller)"
        } else if delta < -0.5 {
            return "\(bytes(before)) → \(bytes(after)) (\(Int((-delta).rounded()))% larger)"
        }
        return "\(bytes(before)) → \(bytes(after))"
    }
}

// MARK: - LibreOffice

/// Locates a LibreOffice installation and runs headless conversions with it.
///
/// Office formats (.docx/.xlsx/.pptx) have no first-party macOS conversion API
/// — Apple gives no way to read them, and reimplementing OOXML is out of scope
/// for this app. LibreOffice does it well, is free, and ships a headless CLI,
/// so the app detects it rather than bundling it (bundling would add ~800 MB
/// and a licensing obligation).
enum LibreOffice {

    /// Standard install locations, in preference order: the Homebrew cask and
    /// the .dmg both land in /Applications; the rest cover manual installs.
    private static let candidatePaths = [
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/opt/homebrew/bin/soffice",
        "/usr/local/bin/soffice",
        "\(NSHomeDirectory())/Applications/LibreOffice.app/Contents/MacOS/soffice"
    ]

    /// Path to `soffice`, or `nil` when LibreOffice isn't installed.
    static var executable: URL? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isInstalled: Bool { executable != nil }

    /// Convert `input` into `filter` format, writing into `outputDirectory`.
    ///
    /// - Parameter filter: a LibreOffice output filter, e.g. `"pdf"`,
    ///   `"docx"`, `"xlsx:Calc MS Excel 2007 XML"`.
    /// - Returns: the produced file.
    ///
    /// Runs with a private user profile (`-env:UserInstallation`) so a
    /// conversion never collides with a LibreOffice window the user has open —
    /// without it, soffice refuses to start a second instance and the job
    /// hangs forever.
    static func convert(input: URL,
                        to filter: String,
                        outputDirectory: URL,
                        timeout: TimeInterval = 180) throws -> URL {
        guard let soffice = executable else { throw ForgeError.libreOfficeMissing }

        let profile = outputDirectory.appendingPathComponent("lo-profile", isDirectory: true)
        let process = Process()
        process.executableURL = soffice
        process.arguments = [
            "-env:UserInstallation=file://\(profile.path)",
            "--headless", "--norestore", "--invisible",
            "--convert-to", filter,
            "--outdir", outputDirectory.path,
            input.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Guard against a hung soffice: kill it rather than blocking the job
        // queue forever on one bad file.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw ForgeError.toolFailed("LibreOffice", "timed out after \(Int(timeout))s on \(input.lastPathComponent)")
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""

        // LibreOffice names the output after the input stem with the new
        // extension. Find whatever landed rather than trusting that rule —
        // some filters (e.g. "xlsx:...") don't follow it exactly.
        let wantedExt = filter.split(separator: ":").first.map(String.init) ?? filter
        let stem = input.deletingPathExtension().lastPathComponent
        let expected = outputDirectory.appendingPathComponent("\(stem).\(wantedExt)")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }

        if let produced = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == wantedExt.lowercased() }) {
            return produced
        }

        throw ForgeError.toolFailed("LibreOffice",
                                    output.isEmpty ? "produced no output for \(input.lastPathComponent)"
                                                   : output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
