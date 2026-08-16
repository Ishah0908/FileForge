//
//  LayoutAnalyzer.swift
//  FileForge
//
//  Recovers document STRUCTURE from a PDF, not just its characters.
//
//  A PDF has no paragraphs, tables or columns — but it does record where every
//  glyph sits on the page, and that geometry is what a reader's eye uses to
//  see a table. This reconstructs the same thing mechanically:
//
//    • Lines whose baselines share a y position are one ROW.
//    • Recurring x positions across many rows are COLUMN boundaries.
//    • A row whose pieces land in those columns is a TABLE row; a row that
//      spans the page as one run of text is a PARAGRAPH.
//
//  Getting this right is the difference between "PDF to Word" producing an
//  editable payslip and producing an undifferentiated wall of text.
//
//  Author: Ibrahim Sultan
//

import Foundation
import PDFKit

enum LayoutAnalyzer {

    /// One piece of text with its position on the page.
    struct Fragment {
        let text: String
        let rect: CGRect
    }

    /// A horizontal band of the page: either flowing text or table cells.
    enum Block {
        /// Ordinary text — a heading or a sentence spanning the page.
        case paragraph(String)
        /// Cells that lined up into columns.
        case row([String])
    }

    /// One page's reconstructed structure.
    struct PageLayout {
        let blocks: [Block]
        /// Column x positions detected on this page, for building the table.
        let columnCount: Int
        /// Each column's share of the page width, 0…1, summing to 1.
        ///
        /// Carried through to Word so columns keep their ORIGINAL proportions.
        /// Dividing the page evenly instead is what turns a name column into a
        /// four-character-wide strip that stacks "Ibrahimuddin" vertically.
        let columnWeights: [Double]
    }

    // MARK: - Extraction

    /// Pull every line of a page with its bounding box.
    ///
    /// `selectionsByLine()` is the key API: PDFKit has already done the hard
    /// work of grouping glyphs into visual lines, so this inherits its reading
    /// order rather than re-deriving it from raw glyph runs.
    static func fragments(of page: PDFPage) -> [Fragment] {
        guard let selection = page.selection(for: page.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Fragment(text: text, rect: line.bounds(for: page))
        }
    }

    // MARK: - Structure

    /// Group a page's fragments into rows, then classify each row.
    ///
    /// - Parameter rowTolerance: how far apart two baselines can be and still
    ///   count as the same row. Scaled from the text height rather than fixed,
    ///   so it holds for both 8pt tables and 24pt headings.
    static func analyze(page: PDFPage) -> PageLayout {
        let pieces = fragments(of: page)
        guard !pieces.isEmpty else {
            return PageLayout(blocks: [], columnCount: 0, columnWeights: [])
        }
        let pageWidth = page.bounds(for: .cropBox).width

        // Typical line height drives the row-grouping tolerance.
        let heights = pieces.map(\.rect.height).sorted()
        let medianHeight = heights[heights.count / 2]
        let rowTolerance = max(2.0, medianHeight * 0.6)

        // 1. Group fragments into rows by baseline (y descends down the page).
        var rows: [[Fragment]] = []
        for piece in pieces.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let lastIndex = rows.indices.last,
               let reference = rows[lastIndex].first,
               abs(reference.rect.midY - piece.rect.midY) <= rowTolerance {
                rows[lastIndex].append(piece)
            } else {
                rows.append([piece])
            }
        }
        // Within a row, read left to right.
        for i in rows.indices {
            rows[i].sort { $0.rect.minX < $1.rect.minX }
        }

        // 2. Find column boundaries: x positions that recur across many rows.
        //    A one-off indent isn't a column; a left edge shared by a dozen
        //    rows is.
        var xTally: [Int: Int] = [:]
        for row in rows where row.count > 1 {
            for piece in row {
                // Bucket to the nearest 6pt so slightly ragged edges agree.
                xTally[Int((piece.rect.minX / 6).rounded()) * 6, default: 0] += 1
            }
        }
        let multiCellRows = rows.filter { $0.count > 1 }.count
        let threshold = max(2, multiCellRows / 5)
        var columns = xTally.filter { $0.value >= threshold }.keys.sorted()

        // Merge column edges that sit close together.
        //
        // Text that starts a few points apart across rows registers as several
        // distinct columns, and every extra column steals width from the real
        // ones — the page only has 8.5 inches to divide, so eight detected
        // columns leave about an inch each and long values wrap badly. 40pt
        // (~0.55in) is narrower than any genuine column of text but wide
        // enough to absorb ragged edges.
        var merged: [Int] = []
        for column in columns {
            if let last = merged.last, column - last < 40 { continue }
            merged.append(column)
        }
        columns = merged

        // 3. Classify each row.
        var blocks: [Block] = []
        for row in rows {
            if row.count == 1 {
                // A single fragment can still be a table row: some PDFs draw a
                // whole line as one text run and separate the columns with
                // spaces (monospaced reports and anything produced by a
                // typewriter-style generator). Two or more consecutive spaces
                // is the same column signal used elsewhere in the app.
                let text = row[0].text
                let cells = text.components(separatedBy: "  ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if cells.count > 1 {
                    blocks.append(.row(cells))
                } else {
                    blocks.append(.paragraph(text))
                }
                continue
            }
            // Place each fragment in its column slot so cells stay aligned
            // even when a row skips columns (very common in payslips, where a
            // line fills the earnings side but not the deductions side).
            var cells = [String](repeating: "", count: max(columns.count, row.count))
            for piece in row {
                let slot = nearestColumn(piece.rect.minX, in: columns) ?? 0
                let index = min(slot, cells.count - 1)
                cells[index] = cells[index].isEmpty
                    ? piece.text
                    : cells[index] + " " + piece.text
            }
            blocks.append(.row(cells))
        }

        // 4. Column widths from the ACTUAL gaps between column edges, so a
        //    wide name column stays wide. The last column runs to the right
        //    margin (approximated by the widest content on the page).
        var weights: [Double] = []
        if !columns.isEmpty {
            let rightEdge = max(pieces.map(\.rect.maxX).max() ?? pageWidth,
                                CGFloat(columns.last ?? 0) + 40)
            var edges = columns.map { CGFloat($0) }
            edges.append(rightEdge)
            let spans = (0..<columns.count).map { max(12, edges[$0 + 1] - edges[$0]) }
            let total = spans.reduce(0, +)
            if total > 0 { weights = spans.map { Double($0 / total) } }
        }

        return PageLayout(blocks: blocks,
                          columnCount: columns.count,
                          columnWeights: weights)
    }

    /// Index of the column whose left edge is nearest to `x`.
    private static func nearestColumn(_ x: CGFloat, in columns: [Int]) -> Int? {
        guard !columns.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, column) in columns.enumerated() {
            let distance = abs(CGFloat(column) - x)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    /// Analyze every page of a document in order.
    static func analyze(document: PDFDocument) -> [PageLayout] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index).map { analyze(page: $0) }
        }
    }
}
