import SwiftUI

/// Shown instead of ssh's error when a server's host key isn't trusted: the
/// key's fingerprint, what it conflicts with, and a button to trust it. A
/// changed key that no other address of the server vouches for asks again.
struct HostKeyView: View {
    var model: AppModel
    var problem: HostKeyProblem
    @State private var confirmReplace = false

    private var serverName: String { model.transport?.displayName ?? problem.address }

    var body: some View {
        // Laid out by hand: ContentUnavailableView squeezes the key table.
        ScrollView {
        VStack(spacing: 14) {
            Image(systemName: problem.needsConfirmation ? "exclamationmark.shield" : "key")
                .font(.system(size: 36))
                .foregroundStyle(problem.needsConfirmation ? .orange : .secondary)
            Text(problem.kind == .unknown ? "Trust \(serverName)\u{2019}s host key?" : "\(serverName)\u{2019}s host key has changed")
                .font(.title3.bold())
            Text(problem.summary)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Address", Text(problem.address).lineLimit(1).minimumScaleFactor(0.6))
                row(problem.kind == .changed ? "New key" : "Key", fingerprint(problem.fingerprint))
                if let previous = problem.previousFingerprint {
                    row("Trusted key", fingerprint(previous))
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if problem.kind == .unknown {
                Text("If you can, compare the key with the server\u{2019}s own: run `ssh-keygen -lf /etc/ssh/ssh_host_\(problem.keyType.lowercased())_key.pub` there.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .textSelection(.enabled)
            } else if problem.needsConfirmation {
                Text("Only replace it if you know why the key changed.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Try Again", action: model.retryNow)
                Button(trustTitle) {
                    if problem.needsConfirmation {
                        confirmReplace = true
                    } else {
                        Task { await model.trustHostKey(problem) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("hostKey.trust")
            }
            .fixedSize()
        }
        .padding()
        .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .confirmationDialog("Replace the trusted key for \(problem.address)?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace Key and Connect", role: .destructive) {
                Task { await model.trustHostKey(problem) }
            }
        } message: {
            Text("""
                \(ThisDevice.sentenceName) will trust \(problem.fingerprint) for \(problem.address) from now on. \
                If someone is intercepting the connection, they would see what the app sends to the server.
                """)
        }
    }

    private var trustTitle: String {
        switch problem.kind {
        case .unknown: return "Trust and Connect"
        case .changed: return problem.needsConfirmation ? "Replace Key\u{2026}" : "Replace Key and Connect"
        }
    }

    private func row(_ label: String, _ value: some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            value
        }
    }

    private func fingerprint(_ fp: String) -> some View {
        // Keys never wrap: a fingerprint split over lines is hard to compare.
        // Narrow screens shrink it instead.
        Text(fp).font(.callout.monospaced()).lineLimit(1).minimumScaleFactor(0.5)
    }
}
