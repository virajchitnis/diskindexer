import SwiftUI

/// Lists the server's schedules: what each reindexes, how often, and how its
/// last run went. Schedules are added from a disk's or collection's menu.
struct SchedulesView: View {
    var model: AppModel
    var onClose: () -> Void

    @State private var deleting: Schedule?
    @State private var editing: ScheduleDraft?

    private var serverName: String { model.transport?.displayName ?? "the server" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedules").font(.headline)
                Text(scheduleRunNote(info: model.info, serverName: serverName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if model.schedules.isEmpty {
                ContentUnavailableView("No schedules", systemImage: "calendar.badge.clock",
                                       description: Text("Right-click a disk or collection in the sidebar and choose Schedule Reindexing\u{2026}"))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.schedules) { s in
                            ScheduleRow(model: model, schedule: s,
                                        onEdit: { editing = draft(for: s) },
                                        onDelete: { deleting = s })
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Runs are skipped, and nothing is removed from the index, while a folder isn\u{2019}t available, e.g. when its disk is unplugged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .macFrame(minWidth: 540, minHeight: 360, idealHeight: 440)
        .task {
            // Scheduled runs start on the server; keep the list and the jobs
            // (which show their progress) current while this is open.
            while !Task.isCancelled {
                await model.refreshSchedules()
                await model.refreshJobs()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .sheet(item: $editing) { draft in
            ScheduleEditor(model: model, draft: draft) { editing = nil }
        }
        .confirmationDialog("Delete the schedule for \u{201C}\(deleting?.targetTitle ?? "")\u{201D}?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let s = deleting { Task { await model.deleteSchedule(s) } }
                deleting = nil
            }
        } message: {
            Text("The index isn\u{2019}t changed.")
        }
    }

    private func draft(for s: Schedule) -> ScheduleDraft {
        let saved = model.diskNodes.first { $0.label == s.disk }?
            .collections.first { $0.label == s.collection }?.rootPath ?? ""
        return ScheduleDraft(editing: s, savedLocation: saved)
    }
}

struct ScheduleRow: View {
    var model: AppModel
    var schedule: Schedule
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let s = schedule
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(s.targetTitle, systemImage: s.isCollection ? "folder" : "externaldrive")
                    .font(.body.weight(.medium))
                Spacer()
                Toggle("On", isOn: Binding(get: { s.enabled },
                                           set: { on in Task { await model.setScheduleEnabled(s, on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help(s.enabled ? "Turn this schedule off" : "Turn this schedule on")
            }
            Text(s.intervalDescription(timeZone: model.info?.timeZone) + (s.path.map { " \u{00B7} from \($0)" } ?? ""))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = s.lastStatusTitle {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(lastRunText(status))
                    if let message = s.lastMessage, !message.isEmpty {
                        Text("\u{2014} \(message)").textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(s.lastStatus == "failed" ? .red : s.lastRunNeedsAttention ? .orange : .secondary)
            }
            HStack {
                Text(nextRunText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Run Now") { Task { await model.runSchedule(s) } }
                    .disabled(s.lastStatus == "running")
                Button("Edit\u{2026}", action: onEdit)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete this schedule")
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func lastRunText(_ status: String) -> String {
        guard let at = schedule.lastRunAt else { return status }
        return "\(status) \(at.formatted(.relative(presentation: .named)))"
    }

    private var nextRunText: String {
        guard let next = schedule.nextRunAt else { return "Off" }
        if next <= Date() { return "Due now" }
        return "Next run \(next.formatted(.relative(presentation: .named))), \(next.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Creates or edits one schedule.
struct ScheduleEditor: View {
    var model: AppModel
    @State var draft: ScheduleDraft
    var onDone: () -> Void

    @State private var saving = false
    @State private var error: String?
    @State private var browsing = false

    init(model: AppModel, draft: ScheduleDraft, onDone: @escaping () -> Void) {
        self.model = model
        _draft = State(initialValue: draft)
        self.onDone = onDone
    }

    private var serverName: String { model.transport?.displayName ?? "the server" }

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    HStack {
                        TextField(draft.isCollection ? "Read from" : "Mount path", text: $draft.path,
                                  prompt: Text(draft.isCollection ? draft.savedLocation : "/media/me/MyDisk"))
                            .accessibilityIdentifier("schedule.path")
                        Button("Browse\u{2026}") { browse() }
                    }
                } footer: {
                    Text(draft.isCollection
                         ? "Leave empty to read the collection from its saved location. Another folder, such as a copy on \(serverName), is read instead and the collection keeps its saved location."
                         : "Every run reads the whole disk from here, like Reindex.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("Every")
                        TextField("Every", value: $draft.every, format: .number)
                            .labelsHidden()
                            .frame(width: 50)
                            .accessibilityIdentifier("schedule.every")
                        Stepper("Every", value: $draft.every, in: 1...365).labelsHidden()
                        Picker("Unit", selection: $draft.unit) {
                            ForEach(ScheduleDraft.Unit.allCases) { Text($0.title(draft.every)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if draft.timeApplies {
                        HStack {
                            Toggle("At", isOn: $draft.useTime)
                            DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .disabled(!draft.useTime)
                            if let tz = model.info?.timeZone, !tz.isEmpty {
                                Text("\(tz), \(serverName)\u{2019}s time").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("On", isOn: $draft.enabled)
                } footer: {
                    Text(scheduleRunNote(info: model.info, serverName: serverName)
                         + " A run is skipped, and nothing is removed from the index, while the folder isn\u{2019}t there, is empty, or its disk isn\u{2019}t mounted.")
                        .foregroundStyle(.secondary)
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
                Button("Cancel", role: .cancel, action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(draft.existing == nil ? "Add Schedule" : "Save") { save() }
                    .accessibilityIdentifier("schedule.save")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || saving)
            }
            .padding(12)
        }
        .macFrame(minWidth: 520, minHeight: 400, idealHeight: 440, maxHeight: 500)
        .sheet(isPresented: $browsing) {
            RemoteFolderPicker(model: model, startPath: draft.path.isEmpty ? draft.savedLocation : draft.path) { picked in
                if let picked { draft.path = picked }
                browsing = false
            }
        }
    }

    private func browse() {
        if model.transport?.isLocal == true, let pick = model.pickLocalFolder {
            if let path = pick() { draft.path = path }
        } else {
            browsing = true
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await model.saveSchedule(draft.request, id: draft.existing?.scheduleID)
                onDone()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
