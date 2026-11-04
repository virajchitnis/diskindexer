import SwiftUI

struct JobsView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Index Jobs").font(.headline)
                Spacer()
                if model.jobs.contains(where: { $0.state != .running }) {
                    Button("Clear Finished") { model.clearFinishedJobs() }
                        #if os(macOS)
                        .buttonStyle(.link)
                        #else
                        .buttonStyle(.borderless)
                        #endif
                }
            }
            .padding(12)
            Divider()
            if model.jobs.isEmpty {
                Text("No index jobs yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            JobRow(job: job) { Task { await model.cancelJob(job.id) } }
                            Divider()
                        }
                    }
                }
            }
        }
        // Scheduled runs start on the server without this app knowing.
        .task { await model.refreshJobs() }
    }
}

struct JobRow: View {
    var job: Job
    var onCancel: () -> Void

    var body: some View {
        // Redraw every second so elapsed time and ETA tick between updates.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(job.request.disk, systemImage: "externaldrive")
                        .font(.body.weight(.medium))
                    if job.schedule != nil {
                        Text("Scheduled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if job.state == .running {
                        Button("Cancel", action: onCancel)
                            .controlSize(.small)
                    }
                }
                Text(job.sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = job.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack {
                    Text(job.phaseTitle)
                        .accessibilityIdentifier("job.phase")
                        .foregroundStyle(job.state == .failed ? .red : (job.errorCount > 0 || job.state == .interrupted) ? .orange : .primary)
                    Spacer()
                    Text(detail(now: ctx.date))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                if job.errorCount > 0 {
                    UnreadablePaths(job: job)
                }
                if let err = job.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(job.state == .interrupted ? .orange : .red)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
        }
    }

    private func detail(now: Date) -> String {
        if let s = job.stats {
            return "+\(s.added) ~\(s.updated) −\(s.deleted) in \(Format.duration(s.elapsedMs / 1000))"
        }
        let elapsed = (job.finishedAt ?? now).timeIntervalSince(job.startedAt)
        var parts = ["\(Format.commas(Int64(job.processed))) files"]
        // Rate and time left only mean something while walking files.
        if job.state == .running && job.progress.phase == "indexing" {
            let rate = Format.rate(processed: job.processed, elapsed: elapsed)
            if !rate.isEmpty { parts.append(rate) }
            let eta = Format.eta(processed: job.processed, total: job.progress.total, elapsed: elapsed)
            if !eta.isEmpty { parts.append(eta) }
        }
        return parts.joined(separator: " · ")
    }
}

/// The paths a job couldn't read. While running, just the count; once done,
/// an expandable list (the server keeps the first 50).
struct UnreadablePaths: View {
    var job: Job
    @State private var expanded = false

    var body: some View {
        let n = job.errorCount
        let noun = n == 1 ? "path" : "paths"
        if job.state == .running {
            Label("\(n) unreadable \(noun) so far", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(job.stats?.errors ?? [], id: \.self) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.path).font(.caption.monospaced())
                            Text(e.error).font(.caption2).foregroundStyle(.secondary)
                        }
                        .textSelection(.enabled)
                    }
                    let listed = job.stats?.errors?.count ?? 0
                    if n > listed {
                        Text("\u{2026} and \(n - listed) more").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("What was indexed there before was kept.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Couldn\u{2019}t read \(n) \(noun)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
