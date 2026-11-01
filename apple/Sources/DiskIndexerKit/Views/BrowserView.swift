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

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model, onReindex: { node in
                indexDraft = IndexDraft(node: node)
            }, onAddCollection: { node in
                indexDraft = IndexDraft(addingTo: node)
            })
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            detail
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search files and folders")
        .inspector(isPresented: $showInspector) {
            DetailView(file: model.selectedFile)
                .inspectorColumnWidth(min: 220, ideal: 280)
        }
        .toolbar {
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
            ToolbarItem {
                Button {
                    showJobs.toggle()
                } label: {
                    Label("Jobs", systemImage: model.runningJobs.isEmpty ? "clock" : "clock.badge")
                }
                .help("Index jobs")
                .popover(isPresented: $showJobs) {
                    JobsView(model: model)
                        .frame(width: 380)
                        .frame(minHeight: 120, maxHeight: 420)
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
        .sheet(item: $indexDraft) { draft in
            IndexSheet(model: model, draft: draft) { started in
                indexDraft = nil
                if started { showJobs = true }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.status {
        case .connected, .reconnecting:
            let offline = model.status != .connected
            VStack(spacing: 0) {
                // Stale results stay usable (copy a path) but look stale.
                ResultsTable(model: model, dimmed: offline)
                    // The table's scroll view otherwise draws past its frame,
                    // under the banner below.
                    .clipped()
                // Below the table, not above it: the table extends under the
                // toolbar and pins its column header over anything on top.
                if case let .reconnecting(reason) = model.status {
                    Divider()
                    Banner(systemImage: "wifi.exclamationmark", retry: model.retryNow) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("Reconnecting to \(model.transport?.displayName ?? "the server")")
                                    .fontWeight(.medium)
                                RetryCountdown(until: model.nextAttempt)
                            }
                            Text("Showing results from before the connection dropped. Searches will run once it\u{2019}s back.")
                            Text(reason).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Divider()
                StatusBar(model: model)
            }
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
                Button("Try Now", action: model.retryNow)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message).textSelection(.enabled)
            } actions: {
                Button("Try Again", action: model.retryNow)
            }
        case .disconnected:
            ContentUnavailableView("Not connected", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Choose a connection from the toolbar."))
        }
    }
}

struct Banner<Content: View>: View {
    var systemImage: String
    var retry: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
            content
            Spacer()
            if let retry {
                Button("Try Now", action: retry)
                    .controlSize(.small)
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
        if model.capped { return "\(n)+ results, refine your search to see more" }
        return n == 1 ? "1 result" : "\(n) results"
    }
}
