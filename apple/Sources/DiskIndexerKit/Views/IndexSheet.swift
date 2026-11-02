import SwiftUI

/// Editable state for the Index Disk sheet.
struct IndexDraft: Identifiable {
    enum Mode {
        case newDisk
        case reindex
        /// Add collections stored anywhere on the server to an existing disk,
        /// without its mount path (the disk itself needn't be plugged in).
        case addCollection
    }

    let id = UUID()
    var mode = Mode.newDisk
    var disk = ""
    var description = ""
    var mountPath = ""
    var autoCollections = true
    var collections: [EditableCollection] = []
    /// The disk's own excludes, comma-separated. Pre-filled from what the
    /// disk was last indexed with; saved with the disk when the run starts.
    var excludes = ""
    /// Apply the server's default excludes (shown read-only in the sheet).
    var useDefaultExcludes = true
    var force = false

    var isReindex: Bool { mode == .reindex }

    init() {}

    /// Prefills from an indexed disk. Manually specified collections whose
    /// roots aren't under the mount path are carried over as manual specs.
    init(node: DiskNode) {
        disk = node.label
        description = node.disks.first?.description ?? ""
        excludes = Self.remembered(node)
        mode = .reindex
        mountPath = node.guessedMountPath ?? ""
        if node.guessedMountPath == nil && !node.collections.isEmpty {
            autoCollections = false
            collections = node.collections.map { EditableCollection(label: $0.label, path: $0.rootPath) }
        }
    }

    init(addingTo node: DiskNode) {
        disk = node.label
        excludes = Self.remembered(node)
        mode = .addCollection
        autoCollections = false
        collections = [EditableCollection(label: "", path: "")]
    }

    private static func remembered(_ node: DiskNode) -> String {
        (node.disks.first?.excludes ?? []).joined(separator: ", ")
    }

    var excludeList: [String] {
        excludes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var title: String {
        switch mode {
        case .newDisk: "Index a Disk"
        case .reindex: "Reindex \u{201C}\(disk)\u{201D}"
        case .addCollection: "Add Collection to \u{201C}\(disk)\u{201D}"
        }
    }

    var request: IndexRequest {
        let colls = autoCollections ? [] : collections
            .filter { !$0.label.isEmpty && !$0.path.isEmpty }
            .map { CollectionSpec(label: $0.label, rootPath: $0.path) }
        return IndexRequest(
            disk: disk.trimmingCharacters(in: .whitespaces),
            // Listed collections don't need the disk's root; leaving it out
            // keeps the disk's root files and other collections untouched.
            mountPath: mode == .addCollection ? "" : mountPath,
            description: description.isEmpty ? nil : description,
            collections: colls.isEmpty ? nil : colls,
            // Always sent, so clearing the field clears the disk's saved
            // excludes (nil would reuse them).
            excludes: excludeList,
            noDefaultExcludes: useDefaultExcludes ? nil : true,
            force: force ? true : nil
        )
    }

    var isValid: Bool {
        let hasCollection = collections.contains { !$0.label.isEmpty && !$0.path.isEmpty }
        guard !disk.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // Auto-detection walks the mount path; listed collections stand alone.
        return autoCollections ? !mountPath.isEmpty : hasCollection
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
            Text(draft.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Disk label", text: $draft.disk, prompt: Text("e.g. Archive 4TB"))
                        .disabled(draft.mode != .newDisk)
                        .accessibilityIdentifier("index.diskLabel")
                    if draft.mode != .addCollection {
                        TextField("Description", text: $draft.description, prompt: Text("Optional"))
                        HStack {
                            TextField("Mount path", text: $draft.mountPath,
                                      prompt: Text(draft.autoCollections ? mountPrompt : "Optional"))
                                .accessibilityIdentifier("index.mountPath")
                            Button("Browse…") { browse(.mount) }
                        }
                    }
                } footer: {
                    Text(headerFooter)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if draft.mode != .addCollection {
                        Toggle("Use top-level folders as collections", isOn: $draft.autoCollections)
                    }
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
                } header: {
                    Text("Collections")
                } footer: {
                    if !draft.autoCollections {
                        Text("A collection's folder can be anywhere on \(model.transport?.displayName ?? "the server"), such as a copy of a folder from this disk. Its files are stored under \u{201C}\(draft.disk.isEmpty ? "Disk" : draft.disk)/Label/\u{2026}\u{201D}.")
                            .foregroundStyle(.secondary)
                    }
                }

                excludesSection

                if draft.mode != .addCollection {
                    Section {
                        Toggle("Rebuild from scratch (wipe this disk's index first)", isOn: $draft.force)
                    }
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
                Button(startTitle) { start() }
                    .accessibilityIdentifier("index.start")
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

    /// Server defaults (read-only, can be turned off for this run) plus the
    /// disk's own excludes, which are remembered for next time.
    @ViewBuilder
    private var excludesSection: some View {
        let defaults = model.info?.defaultExcludes ?? []
        Section {
            if !defaults.isEmpty {
                Toggle(isOn: $draft.useDefaultExcludes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Skip the server\u{2019}s default excludes")
                        Text(defaults.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            TextField(defaults.isEmpty ? "Skip" : "Also skip", text: $draft.excludes, prompt: Text(".snapshots, *.tmp"))
                .accessibilityIdentifier("index.excludes")
        } header: {
            Text("Excludes")
        } footer: {
            Text("Names or patterns of files and folders to skip at any depth, separated by commas. This disk remembers them for next time\(defaults.isEmpty ? "; set default_excludes in the server\u{2019}s config.toml to skip some on every disk" : "").")
                .foregroundStyle(.secondary)
        }
    }

    private var startTitle: String {
        switch draft.mode {
        case .newDisk: "Start Indexing"
        case .reindex: "Reindex"
        case .addCollection: "Add and Index"
        }
    }

    private var headerFooter: String {
        let server = model.transport?.displayName ?? "the server"
        if draft.mode == .addCollection {
            return "The disk doesn't need to be plugged in. Its other collections and root-level files are left as they are. Indexing runs on \(server)."
        }
        if !draft.autoCollections && draft.mountPath.isEmpty {
            return "Without a mount path, only the listed collections are indexed and the disk's other collections and root-level files are left as they are."
        }
        return "Indexing runs on \(server) and keeps going if this app disconnects."
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
