import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    var onReindex: (DiskNode) -> Void

    @State private var expanded: Set<String> = []
    @State private var renaming: Collection?
    @State private var newName = ""
    @State private var deletingCollection: Collection?
    @State private var deletingDisk: DiskNode?

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Label("All Disks", systemImage: "square.stack.3d.up")
                .tag(SidebarItem.allDisks)

            Section("Disks") {
                ForEach(model.diskNodes) { node in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(node.label) },
                        set: { if $0 { expanded.insert(node.label) } else { expanded.remove(node.label) } }
                    )) {
                        ForEach(node.collections) { coll in
                            Label(coll.label, systemImage: "folder")
                                .tag(SidebarItem.collection(disk: node.label, collection: coll.label))
                                .help(coll.rootPath)
                                .contextMenu { collectionMenu(coll) }
                        }
                    } label: {
                        Label(node.label, systemImage: "externaldrive")
                            .tag(SidebarItem.disk(node.label))
                            .help(diskHelp(node))
                            .contextMenu { diskMenu(node) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.status == .connected && model.diskNodes.isEmpty {
                ContentUnavailableView("No disks indexed", systemImage: "externaldrive",
                                       description: Text("Use Index Disk in the toolbar to add one."))
            }
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let c = renaming {
                    let name = newName
                    Task { await model.renameCollection(c, to: name) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete collection \"\(deletingCollection?.label ?? "")\"?",
                            isPresented: Binding(get: { deletingCollection != nil }, set: { if !$0 { deletingCollection = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = deletingCollection { Task { await model.deleteCollection(c) } }
                deletingCollection = nil
            }
        } message: {
            Text("This removes the collection and all of its files from the index. Files on the disk are not touched.")
        }
        .confirmationDialog("Delete disk \"\(deletingDisk?.label ?? "")\"?",
                            isPresented: Binding(get: { deletingDisk != nil }, set: { if !$0 { deletingDisk = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deletingDisk { Task { await model.deleteDisk(d) } }
                deletingDisk = nil
            }
        } message: {
            Text("This removes the disk and everything indexed on it. Files on the disk are not touched.")
        }
    }

    @ViewBuilder
    private func collectionMenu(_ coll: Collection) -> some View {
        Button("Rename…") {
            newName = coll.label
            renaming = coll
        }
        Button("Copy Folder Path") { copyToPasteboard(coll.rootPath) }
        Divider()
        Button("Delete…", role: .destructive) { deletingCollection = coll }
    }

    @ViewBuilder
    private func diskMenu(_ node: DiskNode) -> some View {
        Button("Reindex…") { onReindex(node) }
        Divider()
        Button("Delete…", role: .destructive) { deletingDisk = node }
    }

    private func diskHelp(_ node: DiskNode) -> String {
        let dates = node.disks.compactMap(\.lastIndexedAt)
        guard let last = dates.max() else { return node.label }
        return "\(node.label), last indexed \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}
