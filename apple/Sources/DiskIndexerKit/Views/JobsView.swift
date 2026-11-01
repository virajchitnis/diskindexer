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
                        .buttonStyle(.link)
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
                    Spacer()
                    if job.state == .running {
                        Button("Cancel", action: onCancel)
                            .controlSize(.small)
                    }
                }
                Text(job.request.mountPath)
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
                        .foregroundStyle(job.state == .failed ? .red : .primary)
                    Spacer()
                    Text(detail(now: ctx.date))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
                if let err = job.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
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
        if job.state == .running {
            let rate = Format.rate(processed: job.processed, elapsed: elapsed)
            if !rate.isEmpty { parts.append(rate) }
            let eta = Format.eta(processed: job.processed, total: job.progress.total, elapsed: elapsed)
            if !eta.isEmpty { parts.append(eta) }
        }
        return parts.joined(separator: " · ")
    }
}
