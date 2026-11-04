import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

public func copyToPasteboard(_ s: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
    #else
    UIPasteboard.general.string = s
    #endif
}

/// The main window content: disk/collection sidebar, search results, and the
/// detail inspector. Platform apps add their own connection toolbar item.
public struct BrowserView: View {
    @Bindable var model: AppModel
    @State private var showInspector = false
    @State private var showJobs = false
    @State private var indexDraft: IndexDraft?
    @State private var scheduleDraft: ScheduleDraft?
    @State private var showSchedules = false
    @State private var confirmInstall = false
    @State private var dismissedUpdate: String?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Shown at the top of the sidebar on iPhone and iPad, e.g. a server
    /// menu: there the split view's toolbar doesn't reach its columns.
    private let sidebarAccessory: AnyView?

    public init(model: AppModel, sidebarAccessory: AnyView? = nil) {
        self.model = model
        self.sidebarAccessory = sidebarAccessory
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model, onReindex: { node in
                indexDraft = IndexDraft(node: node)
            }, onAddCollection: { node in
                indexDraft = IndexDraft(addingTo: node)
            }, onReindexCollection: { coll, node in
                indexDraft = IndexDraft(reindexing: coll, in: node)
            }, onSchedule: { draft in
                scheduleDraft = draft
            })
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            #if os(iOS)
            .navigationTitle(model.transport?.displayName ?? "DiskIndexer")
            .toolbar {
                if let sidebarAccessory {
                    ToolbarItem(placement: .topBarLeading) { sidebarAccessory }
                }
            }
            #endif
        } detail: {
            detail
            #if os(iOS)
                // On the results, not the split view: on iPhone the split
                // view's own search field stays with the sidebar.
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Search files and folders")
                .toolbar { iosTools }
            #endif
        }
        #if os(macOS)
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search files and folders")
        #endif
        .inspector(isPresented: $showInspector) {
            DetailView(file: model.selectedFile)
                .inspectorColumnWidth(min: 220, ideal: 280)
        }
        #if os(macOS)
        .toolbar { macTools }
        #endif
        .sheet(item: $indexDraft) { draft in
            IndexSheet(model: model, draft: draft) { started in
                indexDraft = nil
                if started { showJobs = true }
            }
        }
        .sheet(item: $scheduleDraft) { draft in
            ScheduleEditor(model: model, draft: draft) { scheduleDraft = nil }
        }
        .sheet(isPresented: $showSchedules) {
            SchedulesView(model: model) { showSchedules = false }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(installTitle, isPresented: $confirmInstall, titleVisibility: .visible) {
            Button(installButtonTitle) { Task { await model.installServer() } }
        } message: {
            Text(installMessage)
        }
        .sheet(isPresented: Binding(
            get: { model.install != .idle },
            set: { if !$0 { model.dismissInstall() } }
        )) {
            InstallProgressView(model: model)
        }
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private var macTools: some ToolbarContent {
        ToolbarItem {
            Picker("Type", selection: $model.typeFilter) {
                ForEach(TypeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show files, folders, or both")
        }
        ToolbarItem {
            Button {
                indexDraft = IndexDraft()
            } label: {
                Label("Index Disk", systemImage: "plus.circle")
            }
            .help("Index a disk")
            .disabled(model.status != .connected)
        }
        ToolbarItem { jobsButton }
        if model.schedulesAvailable {
            ToolbarItem {
                Button {
                    showSchedules = true
                } label: {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                }
                .help("Periodic reindexing")
                .accessibilityIdentifier("toolbar.schedules")
            }
        }
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.right")
            }
            .help("Show details for the selected item")
        }
    }
    #else
    /// The same actions, fewer buttons: a phone's navigation bar has room
    /// for two. On a phone, details open by tapping a result.
    @ToolbarContentBuilder
    private var iosTools: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if sizeClass == .regular {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
            }
            jobsButton
            Menu {
                Picker("Show", selection: $model.typeFilter) {
                    ForEach(TypeFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button {
                    indexDraft = IndexDraft()
                } label: {
                    Label("Index Disk\u{2026}", systemImage: "plus.circle")
                }
                .disabled(model.status != .connected)
                if model.schedulesAvailable {
                    Button {
                        showSchedules = true
                    } label: {
                        Label("Schedules", systemImage: "calendar.badge.clock")
                    }
                    .accessibilityIdentifier("toolbar.schedules")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("toolbar.more")
        }
    }
    #endif

    private var jobsButton: some View {
        Button {
            showJobs.toggle()
        } label: {
            Label("Jobs", systemImage: model.runningJobs.isEmpty ? "clock" : "clock.badge")
        }
        .help("Index jobs")
        .popover(isPresented: $showJobs) {
            JobsView(model: model)
                .macFrame(width: 380)
                .macFrame(minHeight: 120, maxHeight: 420)
        }
    }

    // MARK: Install / update

    private var serverName: String { model.transport?.displayName ?? "the server" }
    private var isUpdate: Bool { model.status == .connected || model.lastFailure?.reason == .incompatibleVersion }

    private var installTitle: String {
        isUpdate ? "Update diskindexer on \(serverName)?" : "Set up diskindexer on \(serverName)?"
    }

    private var installButtonTitle: String { isUpdate ? "Update" : "Set Up" }

    private var installMessage: String {
        let version = model.serverManager?.bundledVersion.map { " \($0)" } ?? ""
        var text = """
            This copies diskindexer\(version) to ~/.local/bin on \(serverName) over SSH, and sets up \
            and restarts its service (a systemd user service). Your indexes and settings there aren\u{2019}t changed.
            """
        let running = model.runningJobs.count
        if running > 0 {
            text += "\n\n\(running == 1 ? "An index run is" : "\(running) index runs are") in progress and will stop. Files indexed so far are kept."
        }
        return text
    }

    /// Install/Update button for the waiting and failed screens, when the
    /// server is reachable but diskindexer isn't running or is incompatible.
    @ViewBuilder
    private var installButton: some View {
        if model.serverManager != nil {
            switch model.lastFailure?.reason {
            case .notRunning:
                Button("Set Up diskindexer on \(serverName)\u{2026}") { confirmInstall = true }
            case .incompatibleVersion:
                Button("Update diskindexer on \(serverName)\u{2026}") { confirmInstall = true }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.status {
        case .connected, .reconnecting:
            resultsArea
        case .connecting where model.showingSnapshot != nil, .waiting where model.showingSnapshot != nil:
            // Last time's sidebar and results, until the server answers.
            resultsArea
        case .connecting:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .waiting(let message):
            ContentUnavailableView {
                Label("Waiting for \(model.transport?.displayName ?? "the server")", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                VStack(spacing: 6) {
                    Text(message).textSelection(.enabled)
                    RetryCountdown(until: model.nextAttempt)
                }
            } actions: {
                HStack {
                    installButton
                    Button("Try Now", action: model.retryNow)
                }
            }
        case .failed(let message):
            if let problem = model.hostKeyProblem, model.hostKeyTruster != nil {
                HostKeyView(model: model, problem: problem)
            } else {
                ContentUnavailableView {
                    Label("Couldn't connect", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    HStack {
                        installButton
                        Button("Try Again", action: model.retryNow)
                    }
                }
            }
        case .disconnected:
            ContentUnavailableView("Not connected", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Choose a connection from the toolbar."))
        }
    }

    /// While connecting with last time's results on screen.
    private var snapshotBanner: some View {
        let connecting = model.status == .connecting
        let retry: (() -> Void)? = connecting ? nil : { model.retryNow() }
        var reason: String?
        if case .waiting(let r) = model.status { reason = r }
        return Banner(systemImage: "clock.arrow.circlepath", action: retry) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(connecting ? "Connecting to \(serverName)\u{2026}" : "Waiting for \(serverName)")
                        .fontWeight(.medium)
                    if !connecting { RetryCountdown(until: model.nextAttempt) }
                }
                if let saved = model.showingSnapshot {
                    Text("Showing what it had \(saved.formatted(.relative(presentation: .named))). Searching filters these results until it answers.")
                }
                if let reason {
                    Text(reason).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        let offline = model.status != .connected
        VStack(spacing: 0) {
            // Stale results stay usable (copy a path) but look stale.
            ResultsTable(model: model, dimmed: offline, onShowDetails: { showInspector = true })
                // The table's scroll view otherwise draws past its frame,
                // under the banner below.
                .clipped()
            // Below the table, not above it: the table extends under the
            // toolbar and pins its column header over anything on top.
            if let update = model.serverUpdate, model.status == .connected, dismissedUpdate != update.available {
                Divider()
                Banner(systemImage: "arrow.up.circle", actionTitle: "Update\u{2026}", action: { confirmInstall = true },
                       dismiss: { dismissedUpdate = update.available }) {
                    Text("\(serverName) runs diskindexer \(update.current); this app includes \(update.available).")
                }
            }
            switch model.status {
            case .reconnecting(let reason):
                Divider()
                Banner(systemImage: "wifi.exclamationmark", action: model.retryNow) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Reconnecting to \(serverName)")
                                .fontWeight(.medium)
                            RetryCountdown(until: model.nextAttempt)
                        }
                        Text("Showing results from before the connection dropped. Searches will run once it\u{2019}s back.")
                        Text(reason).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            case .connecting, .waiting:
                Divider()
                snapshotBanner
            default:
                EmptyView()
            }
            Divider()
            StatusBar(model: model)
        }
    }
}

struct Banner<Content: View>: View {
    var systemImage: String
    var actionTitle = "Try Now"
    var action: (() -> Void)?
    var dismiss: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
            content
            Spacer()
            if let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide until the next version")
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            // Opaque, so nothing scrolled beneath it shows through.
            Rectangle().fill(.background)
                .overlay(Rectangle().fill(.yellow.opacity(0.25)))
        }
    }
}

/// "Retrying in 8s", counting down to the next connection attempt.
struct RetryCountdown: View {
    var until: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let until {
                let s = max(0, Int(until.timeIntervalSince(ctx.date).rounded(.up)))
                Text(s > 0 ? "\u{2014} retrying in \(s)s" : "\u{2014} retrying\u{2026}")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("\u{2014} trying\u{2026}").foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.searching {
                ProgressView().controlSize(.small)
            }
            if let err = model.searchError {
                Text(err).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(countText)
                    .accessibilityIdentifier("status.count")
            }
            Spacer()
            if let job = model.runningJobs.first {
                Text("\(job.request.disk): \(job.phaseTitle)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !model.duplicateKeys.isEmpty {
                Label("Duplicates", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    .help("Items sharing a name and size are shown in amber")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var countText: String {
        let n = model.results.count
        if model.provisional && model.status != .connected {
            return n == 1 ? "1 match in saved results" : "\(n) matches in saved results"
        }
        if model.capped { return "\(n)+ results, refine your search to see more" }
        return n == 1 ? "1 result" : "\(n) results"
    }
}

/// Progress and outcome of installing or updating diskindexer on a server.
struct InstallProgressView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.install {
            case .idle:
                EmptyView()
            case .running(let log):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Setting up diskindexer\u{2026}").font(.headline)
                }
                logView(log)
            case .done(let report):
                Label(report.onDemand ? "diskindexer \(report.version) is installed" : "diskindexer \(report.version) is running",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if report.onDemand {
                    Text("This server has no systemd, so there\u{2019}s no background service: the app starts diskindexer whenever it connects, and it stops when the app disconnects. Index runs only continue while the app is connected.")
                } else if report.lingerEnabled {
                    Text("It runs in the background, so index runs keep going after your Mac disconnects.")
                } else if let cmd = report.lingerCommand {
                    Text("It runs while you\u{2019}re connected, and stops shortly after the app disconnects \u{2014} including any index run in progress. That\u{2019}s fine for searching and short runs.")
                    Text("Optional: to let long index runs finish on their own after your Mac disconnects, turn on background running by running this on the server once (it asks for your password):")
                    HStack {
                        Text(cmd).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { copyToPasteboard(cmd) }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            case .failed(let message, let log):
                Label("Setup failed", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                logView(log)
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Close") { model.dismissInstall() }
                    .keyboardShortcut(.defaultAction)
                    .disabled({ if case .running = model.install { return true } else { return false } }())
            }
        }
        .padding(20)
        .macFrame(width: 460)
    }

    private func logView(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// A fixed width on macOS. iOS sizes sheets and popovers to the screen.
    func macFrame(width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width)
        #else
        self
        #endif
    }

    /// Size limits on macOS only, as for macFrame(width:).
    func macFrame(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil,
                  maxHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        #else
        self
        #endif
    }
}
