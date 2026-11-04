import SwiftUI

struct ResultsTable: View {
    @Bindable var model: AppModel
    /// Fades the rows, e.g. while showing results from before a dropped
    /// connection. Applied per cell: the table itself is an AppKit view that
    /// SwiftUI's .opacity and overlays don't reach.
    var dimmed = false
    /// Shows the selected item's details; on iPhone a row tap does this.
    var onShowDetails: () -> Void = {}
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    /// Column widths and order. Kept outside the table, which is rebuilt for
    /// each result set, and saved with the window.
    @SceneStorage("resultsTableColumns") private var columns = TableColumnCustomization<FileItem>()

    private var cellOpacity: Double { dimmed ? 0.4 : 1 }

    private static let dateFormat: Date.FormatStyle = .dateTime.year().month(.abbreviated).day().hour().minute()

    var body: some View {
        #if os(iOS)
        if sizeClass == .compact {
            ResultsList(model: model, dimmed: dimmed, onShowDetails: onShowDetails)
        } else {
            table
        }
        #else
        table
        #endif
    }

    private var table: some View {
        Table(model.results, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name) { f in
                Label {
                    Text(f.name)
                } icon: {
                    Image(systemName: f.isDir ? "folder.fill" : "doc")
                        .foregroundStyle(f.isDir ? Color.accentColor : .secondary)
                }
                .foregroundStyle(model.isDuplicate(f) ? Color.orange : Color.primary)
                .help(f.path)
                .opacity(cellOpacity)
            }
            .width(min: 160, ideal: 320)
            .customizationID("name")
            TableColumn("Size", value: \.size) { f in
                Text(Format.size(f.size))
                    .monospacedDigit()
                    .foregroundStyle(model.isDuplicate(f) ? Color.orange : Color.primary)
                    .opacity(cellOpacity)
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")
            TableColumn("Modified", value: \.modifiedAt) { f in
                Text(f.modifiedAt, format: Self.dateFormat)
                    .foregroundStyle(.secondary)
                    .opacity(cellOpacity)
            }
            .width(min: 110, ideal: 150)
            .customizationID("modified")
            TableColumn("Disk", value: \.diskLabel) { f in
                Text(f.diskLabel).opacity(cellOpacity)
            }
                .width(min: 60, ideal: 110)
                .customizationID("disk")
            TableColumn("Collection", value: \.collLabel) { f in
                Text(f.collLabel).opacity(cellOpacity)
            }
                .width(min: 60, ideal: 130)
                .customizationID("collection")
        }
        // See AppModel.resultsGeneration.
        .id(model.resultsGeneration)
        .accessibilityIdentifier("results")
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            let files = model.results.filter { ids.contains($0.id) }
            Button(files.count > 1 ? "Copy \(files.count) Paths" : "Copy Path") {
                copyToPasteboard(files.map(\.path).joined(separator: "\n"))
            }
            .disabled(files.isEmpty)
            Button("Copy Name") {
                copyToPasteboard(files.map(\.name).joined(separator: "\n"))
            }
            .disabled(files.isEmpty)
        } primaryAction: { ids in
            // Double-click or Return copies the path, like Enter in the TUI.
            let paths = model.results.filter { ids.contains($0.id) }.map(\.path)
            copyToPasteboard(paths.joined(separator: "\n"))
        }
        .overlay {
            if model.results.isEmpty && !model.searching && model.searchError == nil {
                ContentUnavailableView.search(text: model.query)
            }
        }
    }
}

#if os(iOS)
/// Results on a narrow screen, where a Table shows only its first column:
/// one row per item with its size, date and location under the name.
struct ResultsList: View {
    @Bindable var model: AppModel
    var dimmed: Bool
    var onShowDetails: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(model.results) { f in
                    Button {
                        model.selection = [f.id]
                        onShowDetails()
                    } label: {
                        row(f)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .leading) {
                        Button("Copy Path", systemImage: "doc.on.doc") { copyToPasteboard(f.path) }
                            .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Copy Path", systemImage: "doc.on.doc") { copyToPasteboard(f.path) }
                        Button("Copy Name", systemImage: "textformat") { copyToPasteboard(f.name) }
                    }
                }
            } header: {
                HStack {
                    Spacer()
                    SortMenu(model: model)
                }
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .opacity(dimmed ? 0.4 : 1)
        // See AppModel.resultsGeneration.
        .id(model.resultsGeneration)
        .accessibilityIdentifier("results")
        .overlay {
            if model.results.isEmpty && !model.searching && model.searchError == nil {
                ContentUnavailableView.search(text: model.query)
            }
        }
    }

    private func row(_ f: FileItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: f.isDir ? "folder.fill" : "doc")
                .foregroundStyle(f.isDir ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name)
                    .lineLimit(2)
                    .foregroundStyle(model.isDuplicate(f) ? Color.orange : Color.primary)
                Text(details(f))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func details(_ f: FileItem) -> String {
        let date = f.modifiedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(Format.size(f.size)) \u{00B7} \(date) \u{00B7} \(f.diskLabel) \u{203A} \(f.collLabel)"
    }
}

/// Sort order for ResultsList, which has no column headers to click.
struct SortMenu: View {
    @Bindable var model: AppModel

    private enum Key: String, CaseIterable {
        case name = "Name", size = "Size", modified = "Modified"
    }

    private func comparator(_ key: Key, _ order: SortOrder) -> KeyPathComparator<FileItem> {
        switch key {
        case .name: KeyPathComparator(\.name, order: order)
        case .size: KeyPathComparator(\.size, order: order)
        case .modified: KeyPathComparator(\.modifiedAt, order: order)
        }
    }

    private var current: (Key, SortOrder)? {
        guard let first = model.sortOrder.first else { return nil }
        for key in Key.allCases {
            for order in [SortOrder.forward, .reverse] where comparator(key, order) == first {
                return (key, order)
            }
        }
        return nil
    }

    var body: some View {
        Menu {
            ForEach(Key.allCases, id: \.self) { key in
                Button {
                    let order: SortOrder = current?.0 == key && current?.1 == .forward ? .reverse : .forward
                    model.sortOrder = [comparator(key, order)]
                } label: {
                    if current?.0 == key {
                        Label(key.rawValue, systemImage: current?.1 == .forward ? "chevron.up" : "chevron.down")
                    } else {
                        Text(key.rawValue)
                    }
                }
            }
        } label: {
            Label(current.map { "Sorted by \($0.0.rawValue)" } ?? "Sort", systemImage: "arrow.up.arrow.down")
                .font(.caption)
        }
        .accessibilityIdentifier("results.sort")
    }
}
#endif
