import SwiftUI

/// Editable state for the Index Disk sheet.
struct IndexDraft: Identifiable {
    let id = UUID()
    var disk = ""
    var description = ""
    var mountPath = ""
    var autoCollections = true
    var collections: [EditableCollection] = []
    var excludes = ""
    var force = false
    var isReindex = false

    init() {}

    /// Prefills from an indexed disk. Manually specified collections whose
    /// roots aren't under the mount path are carried over as manual specs.
    init(node: DiskNode) {
        disk = node.label
        description = node.disks.first?.description ?? ""
        isReindex = true
        mountPath = node.guessedMountPath ?? ""
        if node.guessedMountPath == nil && !node.collections.isEmpty {
            autoCollections = false
            collections = node.collections.map { EditableCollection(label: $0.label, path: $0.rootPath) }
        }
    }

    var request: IndexRequest {
        let ex = excludes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let colls = autoCollections ? [] : collections
            .filter { !$0.label.isEmpty && !$0.path.isEmpty }
            .map { CollectionSpec(label: $0.label, rootPath: $0.path) }
        return IndexRequest(
            disk: disk.trimmingCharacters(in: .whitespaces),
            mountPath: mountPath,
            description: description.isEmpty ? nil : description,
            collections: colls.isEmpty ? nil : colls,
            excludes: ex.isEmpty ? nil : ex,
            force: force ? true : nil
        )
    }

    var isValid: Bool {
        !disk.trimmingCharacters(in: .whitespaces).isEmpty && !mountPath.isEmpty
            && (autoCollections || collections.contains { !$0.label.isEmpty && !$0.path.isEmpty })
    }
}

struct EditableCollection: Identifiable {
    let id = UUID()
    var label: String
    var path: String
}

struct IndexSheet: View {
    var model: AppModel
    @State var draft: IndexDraft
    var onDone: (_ started: Bool) -> Void

    @State private var starting = false
    @State private var error: String?
    @State private var browsing: BrowseTarget?

    enum BrowseTarget: Identifiable {
        case mount
        case collection(UUID)
        var id: String {
            switch self {
            case .mount: "mount"
            case .collection(let u): u.uuidString
            }
        }
    }

    init(model: AppModel, draft: IndexDraft, onDone: @escaping (Bool) -> Void) {
        self.model = model
        _draft = State(initialValue: draft)
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Disk label", text: $draft.disk, prompt: Text("e.g. Archive 4TB"))
                        .disabled(draft.isReindex)
                    TextField("Description", text: $draft.description, prompt: Text("Optional"))
                    HStack {
                        TextField("Mount path", text: $draft.mountPath, prompt: Text(mountPrompt))
                        Button("Browse…") { browse(.mount) }
                    }
                } footer: {
                    Text("Indexing runs on \(model.transport?.displayName ?? "the server") and keeps going if this app disconnects.")
                        .foregroundStyle(.secondary)
                }

                Section("Collections") {
                    Toggle("Use top-level folders as collections", isOn: $draft.autoCollections)
                    if !draft.autoCollections {
                        ForEach($draft.collections) { $c in
                            HStack {
                                TextField("Label", text: $c.label)
                                    .frame(maxWidth: 140)
                                TextField("Path", text: $c.path)
                                Button("Browse…") { browse(.collection(c.id)) }
                                Button {
                                    draft.collections.removeAll { $0.id == c.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Add Collection") {
                            draft.collections.append(EditableCollection(label: "", path: ""))
                        }
                    }
                }

                Section("Options") {
                    TextField("Exclude folders", text: $draft.excludes, prompt: Text(".snapshots, *.cache"))
                    Toggle("Rebuild from scratch (wipe this disk's index first)", isOn: $draft.force)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isReindex ? "Reindex" : "Start Indexing") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || starting)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 460)
        .sheet(item: $browsing) { target in
            RemoteFolderPicker(model: model, startPath: path(for: target)) { picked in
                if let picked { set(picked, for: target) }
                browsing = nil
            }
        }
    }

    private var mountPrompt: String {
        model.info?.os == "darwin" ? "/Volumes/MyDisk" : "/media/me/MyDisk"
    }

    private func path(for target: BrowseTarget) -> String {
        switch target {
        case .mount: return draft.mountPath
        case .collection(let id): return draft.collections.first { $0.id == id }?.path ?? ""
        }
    }

    private func set(_ path: String, for target: BrowseTarget) {
        switch target {
        case .mount:
            draft.mountPath = path
            if draft.disk.isEmpty { draft.disk = (path as NSString).lastPathComponent }
        case .collection(let id):
            if let i = draft.collections.firstIndex(where: { $0.id == id }) {
                draft.collections[i].path = path
                if draft.collections[i].label.isEmpty {
                    draft.collections[i].label = (path as NSString).lastPathComponent
                }
            }
        }
    }

    private func browse(_ target: BrowseTarget) {
        if model.transport?.isLocal == true, let pick = model.pickLocalFolder {
            if let path = pick() { set(path, for: target) }
        } else {
            browsing = target
        }
    }

    private func start() {
        starting = true
        error = nil
        Task {
            do {
                try await model.startIndex(draft.request)
                onDone(true)
            } catch {
                self.error = error.localizedDescription
                starting = false
            }
        }
    }
}

/// Browses directories on the server so a remote mount path can be picked.
struct RemoteFolderPicker: View {
    var model: AppModel
    var startPath: String
    var onPick: (String?) -> Void

    @State private var listing: DirListing?
    @State private var roots: [DirEntry] = []
    @State private var selected: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(roots) { r in
                        Button(r.path) { load(r.path) }
                    }
                } label: {
                    Label("Locations", systemImage: "externaldrive")
                }
                .fixedSize()
                Button {
                    if let p = listing?.parent { load(p) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(listing?.parent == nil)
                .help("Enclosing folder")
                Text(listing?.path ?? "…")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            Divider()
            List(listing?.entries ?? [], selection: $selected) { e in
                Label(e.name, systemImage: "folder")
                    .tag(e.path)
            }
            .contextMenu(forSelectionType: String.self) { _ in
            } primaryAction: { paths in
                if let p = paths.first { load(p) }
            }
            .overlay {
                if let error {
                    Text(error).foregroundStyle(.red).padding()
                } else if listing?.entries.isEmpty == true {
                    Text("No subfolders").foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("Double-click to open a folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onPick(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { onPick(selected ?? listing?.path) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(listing == nil)
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 380)
        .task {
            roots = (try? await model.fsRoots()) ?? []
            let start = startPath.isEmpty ? (roots.first?.path ?? "/") : startPath
            load(start)
        }
    }

    private func load(_ path: String) {
        Task {
            do {
                listing = try await model.listDir(path)
                selected = nil
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
