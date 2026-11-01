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
            VStack(spacing: 0) {
                if case let .reconnecting(reason) = model.status {
                    Banner(text: "Reconnecting… \(reason)", systemImage: "wifi.exclamationmark")
                }
                ResultsTable(model: model)
                Divider()
                StatusBar(model: model)
            }
        case .connecting:
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message).textSelection(.enabled)
            }
        case .disconnected:
            ContentUnavailableView("Not connected", systemImage: "externaldrive.badge.questionmark",
                                   description: Text("Choose a connection from the toolbar."))
        }
    }
}

struct Banner: View {
    var text: String
    var systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow.opacity(0.25))
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
