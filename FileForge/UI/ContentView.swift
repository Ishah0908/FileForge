//
//  ContentView.swift
//  FileForge
//
//  The main window: a tool sidebar, a drag-and-drop file queue, and an
//  inspector holding that tool's options plus the Convert button.
//
//  Layout reasoning: every tool in this app has the same three questions —
//  which tool, which files, what settings — so the window answers them
//  left-to-right and never navigates away. Pick a different tool and your
//  queue stays put, which is what you want when you're compressing the same
//  twelve files you just merged.
//
//  Author: Ibrahim Sultan
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    @StateObject private var runner = JobRunner()
    @State private var isTargeted = false
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            HSplitView {
                queueColumn
                    .frame(minWidth: 360)
                inspector
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { runner.operation },
            set: { if let value = $0 { runner.operation = value } }
        )) {
            ForEach(OperationCategory.allCases) { category in
                let tools = filteredTools(in: category)
                if !tools.isEmpty {
                    Section {
                        ForEach(tools) { tool in
                            toolRow(tool).tag(tool)
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.icon)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Find a tool")
        .safeAreaInset(edge: .top, spacing: 0) { brandHeader }
    }

    private func filteredTools(in category: OperationCategory) -> [Operation] {
        let all = Operation.allCases.filter { $0.category == category }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(query) || $0.subtitle.lowercased().contains(query)
        }
    }

    private func toolRow(_ tool: Operation) -> some View {
        HStack(spacing: 9) {
            Image(systemName: tool.icon)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(runner.operation == tool ? Color.accentColor : .secondary)
            Text(tool.title)
                .font(.callout)
            Spacer(minLength: 0)
            // Flag the LibreOffice dependency in the list, so an unavailable
            // tool is obvious before it's selected rather than after it fails.
            if tool.needsLibreOffice && !LibreOffice.isInstalled {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Needs LibreOffice, which isn't installed")
            }
        }
        .padding(.vertical, 1)
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.down.forward.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [.accentColor, .accentColor.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 0) {
                Text("FileForge").font(.headline)
                Text("\(Operation.allCases.count) tools · all on-device")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Queue column

    private var queueColumn: some View {
        VStack(spacing: 0) {
            queueHeader
            Divider()

            ZStack {
                if runner.items.isEmpty {
                    dropZone
                } else {
                    fileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The whole column is the drop target, not just the empty state —
            // dropping more files onto a populated queue is the normal way to
            // add to it.
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7]))
                        .padding(8)
                        .background(Color.accentColor.opacity(0.06).padding(8))
                        .allowsHitTesting(false)
                }
            }

            if runner.isRunning || runner.overallProgress > 0 {
                Divider()
                progressBar
            }
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(runner.operation.title).font(.headline)
                Text(runner.operation.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                runner.addFilesViaPanel()
            } label: {
                Label("Add Files", systemImage: "plus")
            }
            .controlSize(.small)

            Button {
                runner.clearQueue()
            } label: {
                Label("Clear", systemImage: "xmark")
            }
            .controlSize(.small)
            .disabled(runner.items.isEmpty || runner.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.title3.weight(.medium))
            Text("Accepts \(runner.operation.acceptedDescription) · folders are expanded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…") { runner.addFilesViaPanel() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var fileList: some View {
        List {
            ForEach(runner.items) { item in
                QueueRow(item: item, runner: runner)
            }
            .onMove { runner.move(from: $0, to: $1) }
            .onDelete { indexes in
                for index in indexes.sorted(by: >) where index < runner.items.count {
                    runner.remove(runner.items[index])
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .bottom) {
            if runner.ineligibleCount > 0 {
                Label("\(runner.ineligibleCount) file\(runner.ineligibleCount == 1 ? "" : "s") will be skipped — wrong type for this tool",
                      systemImage: "info.circle")
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: min(1, max(0, runner.overallProgress)))
                .progressViewStyle(.linear)
            if !runner.statusLine.isEmpty {
                Text(runner.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                if runner.operation.needsLibreOffice && !LibreOffice.isInstalled {
                    libreOfficeNotice
                }

                OptionsPanel(operation: runner.operation, options: $runner.options)

                destinationSection

                if !runner.producedFiles.isEmpty {
                    resultsSection
                }
            }
            .padding(16)
        }
        .background(.background.secondary)
        .safeAreaInset(edge: .bottom, spacing: 0) { runFooter }
    }

    private var libreOfficeNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("LibreOffice required", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Office formats have no conversion API on macOS. Install LibreOffice once — it's free and open source — and this tool starts working.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("brew install --cask libreoffice")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            Link("Or download from libreoffice.org",
                 destination: URL(string: "https://www.libreoffice.org/download/download-libreoffice/")!)
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.09)))
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Save to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(runner.outputFolder.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { runner.chooseOutputFolder() }
                    .controlSize(.small)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.5)))
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Created \(runner.producedFiles.count) file\(runner.producedFiles.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(runner.producedFiles.prefix(6), id: \.self) { url in
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill").font(.caption2).foregroundStyle(.tint)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(url.lastPathComponent)")
            }
            if runner.producedFiles.count > 6 {
                Text("and \(runner.producedFiles.count - 6) more…")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Button {
                runner.revealOutputs()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.08)))
    }

    private var runFooter: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 10) {
                if runner.isRunning {
                    Button("Cancel") { runner.cancel() }
                        .controlSize(.large)
                }
                Button {
                    runner.run()
                } label: {
                    HStack(spacing: 6) {
                        if runner.isRunning {
                            ProgressView().controlSize(.small)
                            Text("Converting…")
                        } else {
                            Image(systemName: "bolt.fill")
                            Text(runButtonTitle)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!runner.canRun)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(.bar)
    }

    private var runButtonTitle: String {
        let count = runner.eligibleItems.count
        if count == 0 { return "Add files to start" }
        if runner.operation.inputMode == .combined { return "\(runner.operation.title) (\(count))" }
        return "Convert \(count) file\(count == 1 ? "" : "s")"
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                      let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { continue }
                urls.append(url)
            }
            if !urls.isEmpty { runner.add(urls: urls) }
        }
        return true
    }
}

// MARK: - Queue row

/// One file in the queue: name, size, live status, and its results.
private struct QueueRow: View {
    @ObservedObject var item: QueueItem
    let runner: JobRunner

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(item.sizeText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if !detail.isEmpty {
                        Text("·").font(.caption2).foregroundStyle(.quaternary)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                    }
                }

                if item.status == .running, item.progress > 0 {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 4)

            if case .done = item.status, let first = item.outputs.first {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([first])
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help(item.outputs.count > 1
                      ? "Reveal \(item.outputs.count) output files"
                      : "Reveal \(first.lastPathComponent)")
            }

            Button {
                runner.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(runner.isRunning)
            .help("Remove from queue")
        }
        .padding(.vertical, 3)
        .help(helpText)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch item.status {
        case .failed(let message): return message
        case .skipped(let reason): return reason
        case .done:
            if !item.note.isEmpty { return item.note }
            if item.outputs.count > 1 { return "\(item.outputs.count) files created" }
            return item.outputs.first?.lastPathComponent ?? "Done"
        case .running: return "Converting…"
        case .waiting: return ""
        }
    }

    private var detailColor: Color {
        switch item.status {
        case .failed: return .red
        case .skipped: return .orange
        case .done: return .secondary
        default: return .secondary
        }
    }

    private var helpText: String {
        switch item.status {
        case .failed(let message): return message
        case .skipped(let reason): return reason
        default: return item.url.path
        }
    }
}

#Preview {
    ContentView()
}
