import SwiftUI

struct ResultsTable: View {
    @Bindable var model: AppModel

    private static let dateFormat: Date.FormatStyle = .dateTime.year().month(.abbreviated).day().hour().minute()

    var body: some View {
        Table(model.results, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { f in
                Label {
                    Text(f.name)
                } icon: {
                    Image(systemName: f.isDir ? "folder.fill" : "doc")
                        .foregroundStyle(f.isDir ? Color.accentColor : .secondary)
                }
                .foregroundStyle(model.isDuplicate(f) ? Color.orange : Color.primary)
                .help(f.path)
            }
            .width(min: 160, ideal: 320)
            TableColumn("Size", value: \.size) { f in
                Text(Format.size(f.size))
                    .monospacedDigit()
                    .foregroundStyle(model.isDuplicate(f) ? Color.orange : Color.primary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Modified", value: \.modifiedAt) { f in
                Text(f.modifiedAt, format: Self.dateFormat)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Disk", value: \.diskLabel)
                .width(min: 60, ideal: 110)
            TableColumn("Collection", value: \.collLabel)
                .width(min: 60, ideal: 130)
        }
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
