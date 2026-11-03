import SwiftUI

struct DetailView: View {
    var file: FileItem?

    var body: some View {
        if let f = file {
            Form {
                Section {
                    LabeledContent("Name", value: f.name)
                    LabeledContent("Type", value: f.isDir ? "Folder" : (f.extension.isEmpty ? "File" : f.extension.uppercased() + " file"))
                    LabeledContent("Size") {
                        Text("\(Format.size(f.size)) (\(Format.commas(f.size)) bytes)")
                    }
                    LabeledContent("Modified") {
                        Text(f.modifiedAt.formatted(date: .long, time: .shortened))
                    }
                }
                Section {
                    LabeledContent("Disk", value: f.diskLabel)
                    LabeledContent("Collection", value: f.collLabel.isEmpty ? "(disk root)" : f.collLabel)
                }
                Section("Path") {
                    Text(f.path)
                        .textSelection(.enabled)
                        .font(.callout.monospaced())
                    Button("Copy Path") { copyToPasteboard(f.path) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("No Selection", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Select a single item to see its details."))
        }
    }
}
