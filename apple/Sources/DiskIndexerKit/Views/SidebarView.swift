import SwiftUI

/// A move awaiting confirmation in the sidebar.
struct PendingMove: Identifiable {
    var collection: Collection
    var target: String
    var id: String { "\(collection.db)#\(collection.id)>\(target)" }
}

/// Drag payload for a collection row. A plain string keeps it simple; the
/// prefix stops random dropped text from being taken for a collection.
enum CollectionDrag {
    static let prefix = "diskindexer-collection:"

    static func payload(_ c: Collection) -> String {
        "\(prefix)\(c.id)@\(c.db)"
    }

    static func parse(_ s: String) -> (db: String, id: Int64)? {
        guard s.hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count)
        guard let at = rest.firstIndex(of: "@"), let id = Int64(rest[..<at]) else { return nil }
        return (String(rest[rest.index(after: at)...]), id)
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    var onReindex: (DiskNode) -> Void
    var onAddCollection: (DiskNode) -> Void

    @State private var expanded: Set<String> = []
    @State private var renaming: Collection?
    @State private var newName = ""
    @State private var deletingCollection: Collection?
    @State private var deletingDisk: DiskNode?
    @State private var pendingMove: PendingMove?
    /// Why a dropped collection can't go to that disk, shown instead of the
    /// move confirmation.
    @State private var blockedMove: String?
    @State private var dropTarget: String?
    @Environment(\.undoManager) private var undoManager

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
                                .draggable(CollectionDrag.payload(coll)) {
                                    Label(coll.label, systemImage: "folder")
                                        .padding(6)
                                }
                        }
                    } label: {
                        Label(node.label, systemImage: "externaldrive")
                            .tag(SidebarItem.disk(node.label))
                            .help(diskHelp(node))
                            .contextMenu { diskMenu(node) }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .opacity(dropTarget == node.label ? 1 : 0)
                            )
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, on: node)
                            } isTargeted: { targeted in
                                // Changing sidebar state inside AppKit's drag
                                // callbacks makes the outline view re-enter its
                                // delegate; apply it on the next turn instead.
                                DispatchQueue.main.async {
                                    if targeted {
                                        dropTarget = node.label
                                    } else if dropTarget == node.label {
                                        dropTarget = nil
                                    }
                                }
                            }
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
        .confirmationDialog(pendingMove.map { "Move \u{201C}\($0.collection.label)\u{201D} to \u{201C}\($0.target)\u{201D}?" } ?? "",
                            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingMove) { move in
            Button("Move") {
                pendingMove = nil
                Task { await perform(move.collection, to: move.target) }
            }
        } message: { move in
            Text("""
                Its paths change from \u{201C}\(move.collection.diskLabel)/\(move.collection.label)/\u{2026}\u{201D} \
                to \u{201C}\(move.target)/\(move.collection.label)/\u{2026}\u{201D}. Nothing is read from either disk; \
                reindex \(move.target) later to pick up other changes. You can undo this.
                """)
        }
        .alert("Can\u{2019}t Move Collection", isPresented: Binding(get: { blockedMove != nil }, set: { if !$0 { blockedMove = nil } })) {
            Button("OK") { blockedMove = nil }
        } message: {
            Text(blockedMove ?? "")
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
        let targets = model.moveTargets(for: coll)
        Menu("Move to") {
            ForEach(targets, id: \.self) { target in
                if model.moveConflict(for: coll, to: target) != nil {
                    // Listed but unavailable, so it's clear why it can't be picked.
                    Button("\(target) \u{2014} already has \u{201C}\(coll.label)\u{201D}") {}
                        .disabled(true)
                } else {
                    Button(target) { pendingMove = PendingMove(collection: coll, target: target) }
                }
            }
        }
        .disabled(targets.isEmpty)
        Divider()
        Button("Delete…", role: .destructive) { deletingCollection = coll }
    }

    @ViewBuilder
    private func diskMenu(_ node: DiskNode) -> some View {
        Button("Reindex…") { onReindex(node) }
        Button("Add Collection…") { onAddCollection(node) }
        Divider()
        Button("Delete…", role: .destructive) { deletingDisk = node }
    }

    private func drop(_ items: [String], on node: DiskNode) -> Bool {
        guard let ref = items.lazy.compactMap(CollectionDrag.parse).first,
              let coll = model.collection(db: ref.db, id: ref.id),
              model.moveTargets(for: coll).contains(node.label)
        else {
            DispatchQueue.main.async { dropTarget = nil }
            return false
        }
        let conflict = model.moveConflict(for: coll, to: node.label)
        // See isTargeted: don't change state during the drop callback.
        DispatchQueue.main.async {
            dropTarget = nil
            if let conflict {
                blockedMove = conflict
            } else {
                pendingMove = PendingMove(collection: coll, target: node.label)
            }
        }
        return conflict == nil
    }

    /// Moves, then registers the reverse move with the window's undo manager.
    private func perform(_ coll: Collection, to target: String) async {
        // Read the environment now: inside a later undo handler this view
        // copy is no longer installed and the environment reads as nil.
        let undo = undoManager
        let origin = coll.diskLabel
        guard let moved = await model.moveCollection(coll, toDisk: target) else { return }
        expanded.insert(target)
        registerReverse(of: moved, back: origin, in: undo)
    }

    /// Registers moving `coll` back to `origin` as the undo (or redo) step.
    /// UndoManager only treats a registration made *during* an undo as the
    /// redo, so the next reverse is registered synchronously in the handler,
    /// before the asynchronous move starts.
    private func registerReverse(of coll: Collection, back origin: String, in undo: UndoManager?) {
        undo?.registerUndo(withTarget: model) { model in
            MainActor.assumeIsolated {
                var after = coll
                after.diskLabel = origin
                registerReverse(of: after, back: coll.diskLabel, in: undo)
                expanded.insert(origin)
                Task { await model.moveCollection(coll, toDisk: origin) }
            }
        }
        undo?.setActionName("Move Collection")
    }

    private func diskHelp(_ node: DiskNode) -> String {
        let dates = node.disks.compactMap(\.lastIndexedAt)
        guard let last = dates.max() else { return node.label }
        return "\(node.label), last indexed \(last.formatted(date: .abbreviated, time: .shortened))"
    }
}
