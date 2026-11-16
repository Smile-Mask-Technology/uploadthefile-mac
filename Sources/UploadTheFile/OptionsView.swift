import SwiftUI
import UploadTheFileCore
import UptfKit

/// The content of an Options window, one per page id.
struct OptionsWindowContent: View {
    var appModel: AppModel
    var pageID: String?
    var close: () -> Void
    @State private var options: OptionsModel?

    var body: some View {
        Group {
            if let options {
                OptionsView(model: options, appModel: appModel, close: close)
            } else {
                ProgressView().controlSize(.small).frame(width: 460, height: 200)
            }
        }
        .task(id: pageID) {
            // A window restored after a relaunch has no list to take the page from.
            guard let pageID, let row = appModel.row(id: pageID), let client = appModel.client else {
                close()
                return
            }
            let model = OptionsModel(page: row.page, client: client)
            options = model
            await model.open()
        }
    }
}

struct OptionsView: View {
    @Bindable var model: OptionsModel
    var appModel: AppModel
    var close: () -> Void

    var body: some View {
        Form {
            if case .failed(let message) = model.load {
                Section {
                    ErrorLine(text: message)
                    Button("Try Again") { Task { await model.open() } }
                }
            } else if case .refused(let message) = model.load {
                Section {
                    PlanNote(message: message, plansURL: appModel.plansURL)
                    Button("Try Again") { Task { await model.open() } }
                }
            }
            nameSection
            passwordSection
            emailSection
            expirySection
            if appModel.row(id: model.pageID)?.supportsDisplayMode ?? true {
                displaySection
            }
            Section {
                Button("Delete…", role: .destructive) {
                    guard let row = appModel.row(id: model.pageID) else { return }
                    Task {
                        if await appModel.delete(row) { close() }
                    }
                }
                .foregroundStyle(.red)
            } footer: {
                Text("The file and its link are removed from your account. People who have the link can no longer open it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(maxHeight: .infinity)
        .navigationTitle("Set up your link · \(model.page.slug)")
        .disabled(model.load == .loading)
        .overlay {
            if model.load == .loading { ProgressView().controlSize(.regular) }
        }
    }

    // MARK: Sections

    private var nameSection: some View {
        Section {
            HStack {
                TextField("Name", text: $model.nameDraft, prompt: Text("my-link"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .onSubmit { if model.canRename { Task { await model.rename() } } }
                Button("Rename") { Task { await model.rename() } }
                    .disabled(!model.canRename)
            }
            if let problem = model.nameProblem { Hint(problem, isError: true) }
            StatusLine(status: model.nameStatus)
            StatusNote(status: model.nameStatus, plansURL: appModel.plansURL)
            HStack {
                Text(model.page.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                CopyButton(text: model.page.url)
            }
        } header: {
            Text("Link name")
        } footer: {
            Text("Renaming gives you a new link, and the old one stops working.")
        }
    }

    private var passwordSection: some View {
        Section {
            if model.passwordProtected == true {
                HStack {
                    Label("Password protection is on", systemImage: "lock.fill")
                    Spacer()
                    Button("Remove Password") { Task { await model.removePassword() } }
                        .disabled(model.passwordStatus.isWorking)
                }
            }
            SecureField("New password", text: $model.newPassword, prompt: Text("6 to 72 characters"))
            SecureField("Repeat password", text: $model.confirmPassword)
            if let problem = model.passwordProblem { Hint(problem, isError: true) }
            if let unread = model.passwordReadError { Hint(unread, isError: true) }
            HStack {
                StatusLine(status: model.passwordStatus)
                Spacer()
                Button(model.passwordProtected == true ? "Change Password" : "Set Password") {
                    Task { await model.setPassword() }
                }
                .disabled(!model.canSavePassword)
            }
            StatusNote(status: model.passwordStatus, plansURL: appModel.plansURL)
        } header: {
            Text("Password protection")
        } footer: {
            Text("Only people with the password can open it.")
        }
    }

    private var emailSection: some View {
        Section {
            Toggle("Ask for their email first", isOn: $model.gateEnabled)
                .disabled(!model.canEditGate)
            TextField("Message", text: $model.gateMessage, prompt: Text("Enter your email to view"), axis: .vertical)
                .lineLimit(1...3)
                .disabled(!model.canEditGate)
                .onChange(of: model.gateMessage) { _, new in
                    let clamped = OptionsRules.clampedGateMessage(new)
                    if clamped != new { model.gateMessage = clamped }
                }
            if let unread = model.gateReadError { Hint(unread, isError: true) }
            HStack {
                StatusLine(status: model.gateStatus)
                Spacer()
                Button("Save") { Task { await model.saveGate() } }
                    .disabled(!model.canSaveGate)
            }
            StatusNote(status: model.gateStatus, plansURL: appModel.plansURL)
        } header: {
            Text("Email")
        }
    }

    private var expirySection: some View {
        Section {
            Toggle("Stays online until I delete it", isOn: $model.neverExpires)
            if !model.neverExpires {
                DatePicker("Stays online until", selection: $model.expiryDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
            if let problem = model.expiryProblem { Hint(problem, isError: true) }
            HStack {
                StatusLine(status: model.expiryStatus)
                Spacer()
                Button("Save") { Task { await model.saveExpiry() } }
                    .disabled(!model.canSaveExpiry)
            }
            StatusNote(status: model.expiryStatus, plansURL: appModel.plansURL)
        } header: {
            Text("Stays online")
        }
    }

    private var displaySection: some View {
        Section {
            Picker("How it opens", selection: $model.displayMode) {
                Text("It opens right in the browser").tag(DisplayMode.preview)
                Text("With a download button").tag(DisplayMode.previewDownload)
                Text("Download button only").tag(DisplayMode.download)
            }
            .labelsHidden()
            .disabled(!model.canChangeDisplay)
            .onChange(of: model.displayMode) { _, mode in
                if model.load == .loaded, mode != model.savedDisplay { Task { await model.saveDisplay() } }
            }
            if let unread = model.displayReadError { Hint(unread, isError: true) }
            StatusLine(status: model.displayStatus)
            StatusNote(status: model.displayStatus, plansURL: appModel.plansURL)
        } header: {
            Text("How it opens")
        } footer: {
            Text("What people see when they open your link.")
        }
    }
}

/// Small explanatory or error text under a control.
private struct Hint: View {
    var text: String
    var isError: Bool

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What happened to the last save of one control: working, saved, or the error, verbatim. A plan
/// refusal is shown by `PlanNote` instead, as its own row.
private struct StatusLine: View {
    var status: OptionsModel.Status

    var body: some View {
        switch status {
        case .idle, .refused:
            EmptyView()
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }
    }
}

/// The plan does not include this setting. The website's own words in a quiet note (lock, secondary
/// text) with a way to the plans: this is information, not something that went wrong.
private struct PlanNote: View {
    var message: String
    var plansURL: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("See Plans") { openURL(plansURL) }
                .buttonStyle(.link)
        }
        .font(.caption)
    }
}

/// A row under a control, present only when the control's last save was a plan refusal.
private struct StatusNote: View {
    var status: OptionsModel.Status
    var plansURL: URL

    var body: some View {
        if case .refused(let message) = status {
            PlanNote(message: message, plansURL: plansURL)
        }
    }
}
