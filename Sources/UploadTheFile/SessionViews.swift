import AppKit
import SwiftUI
import UploadTheFileCore

// MARK: - Small shared pieces

/// The small ✕ that closes a banner or card from its top-right corner.
struct DismissButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("Dismiss")
    }
}

/// "Copy" that turns into "Copied" for a moment. The confirmation is the feedback; no sound.
struct CopyButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            AppModel.shared.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
                .contentTransition(.symbolEffect(.replace))
        }
        .controlSize(.small)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: copied)
        .accessibilityLabel(copied ? "Copied" : "\(title) Link")
    }
}

/// The copy icon that sits next to a link (list rows and the result card). Always visible, in the
/// quiet secondary colour; for about 1.5 s after a copy it is a green check. A button of its own,
/// so VoiceOver and the keyboard reach it without going through the row.
struct CopyIconButton: View {
    var copied: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .imageScale(.medium)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: copied)
        .help(copied ? "Link copied" : "Copy Link")
        .accessibilityLabel(copied ? "Link copied" : "Copy Link")
    }
}

/// `CopyIconButton` for a link that is not in the list: it keeps its own "copied" moment.
struct CopyLinkIconButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        CopyIconButton(copied: copied) {
            AppModel.shared.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

/// A link as text: accent colour, underlined under the pointer, a pointing hand over it; a click
/// opens it in the default browser.
struct OpenLinkButton: View {
    var text: String
    /// What VoiceOver says, for example "Open launch-notes in your browser".
    var accessibilityName: String
    var font: Font = .caption
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font)
                .underline(hovering)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // Push and pop stay paired however the pointer enters, leaves or the view goes away.
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            if hovering {
                hovering = false
                NSCursor.pop()
            }
        }
        .help("Open in your browser")
        .accessibilityLabel(accessibilityName)
    }
}

/// Where a link is being made, in the menu bar window and (larger) in its own window. With `onDismiss`
/// a finished result gets a small ✕ in its top-right corner (the menu bar window; the publish
/// window has a Done button instead).
struct SessionStatusView: View {
    var model: AppModel
    var onDismiss: (() -> Void)?

    init(model: AppModel, onDismiss: (() -> Void)? = nil) {
        self.model = model
        self.onDismiss = onDismiss
    }

    var body: some View {
        let session = model.session
        switch session.phase {
        case .idle:
            EmptyView()
        case .assessing(let url):
            progress("Checking “\(url.lastPathComponent)”…", session)
        case .uploading(let name, let isUpdate):
            progress("\(isUpdate ? "Replacing" : "Uploading") “\(name)”…", session)
        case .confirming(let confirmation):
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                Text("“\(confirmation.name)” is waiting for your answer.")
                    .font(.callout)
                Spacer(minLength: 0)
            }
        case .finished:
            result(session)
        }
    }

    private func progress(_ title: String, _ session: PublishSession) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
                    if session.total > 1 {
                        Text("\(session.position) of \(session.total)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if session.canStop {
                Button("Stop") { model.stopQueue() }
                    .controlSize(.small)
                    .help("Finishes the one in progress and publishes no more.")
            }
        }
    }

    private func result(_ session: PublishSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: session.problems.isEmpty && !session.links.isEmpty
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(session.problems.isEmpty && !session.links.isEmpty ? .green : .orange)
                    .accessibilityHidden(true)
                Text(session.headline)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let onDismiss {
                    DismissButton(action: onDismiss)
                }
            }
            ForEach(Array(session.links.enumerated()), id: \.offset) { _, link in
                HStack(spacing: 6) {
                    // A link that is not a web link is shown as plain text, never as something to click.
                    if model.canOpenLink(link.url) {
                        OpenLinkButton(
                            text: link.url, accessibilityName: "Open “\(link.name)” in your browser",
                            font: .system(.caption, design: .monospaced)
                        ) { model.openLink(link.url) }
                    } else {
                        Text(link.url)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    CopyLinkIconButton(text: link.url)
                }
            }
            if session.links.isEmpty == false || session.problems.count > 1 {
                ForEach(Array(session.problems.enumerated()), id: \.offset) { _, problem in
                    Text("“\(problem.name)”: \(problem.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - The publish window

/// Confirmations, progress and results for a publish, in a window of its own. Opens when something
/// needs a decision (folder list, sensitive path, already published) and for Finder requests.
struct PublishWindowView: View {
    var model: AppModel

    var body: some View {
        Group {
            if let notice = model.notice {
                NoticeView(model: model, notice: notice)
            } else if let batch = model.batch {
                BatchConfirmationView(model: model, batch: batch)
            } else if let confirmation = model.session.confirmation {
                ConfirmationView(model: model, confirmation: confirmation)
            } else {
                ProgressResultView(model: model)
            }
        }
        .frame(width: 460)
        .padding(20)
    }
}

private struct NoticeView: View {
    var model: AppModel
    var notice: Notice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(notice.title).font(.headline)
            Text(notice.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let link = notice.link { CopyButton(text: link) }
                Button("Done") { model.dismissNotice() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ProgressResultView: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SessionStatusView(model: model)
            if model.session.isFinished {
                HStack {
                    Spacer()
                    Button("Done") { model.dismissSession() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private struct BatchConfirmationView: View {
    var model: AppModel
    var batch: BatchConfirmation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(batch.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(batch.detail).font(.callout).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(batch.shown.enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if batch.hiddenCount > 0 {
                        Text("… and \(batch.hiddenCount) more")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .frame(height: min(180, CGFloat(batch.shown.count + (batch.hiddenCount > 0 ? 1 : 0)) * 17 + 16))
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Button("Cancel") { model.cancelBatch() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Publish") { model.confirmBatch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ConfirmationView: View {
    var model: AppModel
    var confirmation: PublishConfirmation

    private var hasWarnings: Bool { !confirmation.warnings.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: hasWarnings ? "exclamationmark.triangle.fill" : (confirmation.folder == nil ? "doc.fill" : "folder.fill"))
                    .font(.system(size: 26))
                    .foregroundStyle(hasWarnings ? Color.orange : Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmation.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    ForEach(confirmation.warnings, id: \.self) { warning in
                        Text(warning).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if hasWarnings {
                        Text("Anyone with the link will be able to open it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let existing = confirmation.existing {
                        Text(existing.pageURL).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let folder = confirmation.folder {
                FolderListView(listing: folder)
            }

            HStack {
                Button("Cancel") { model.decline() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                ForEach(confirmation.options, id: \.choice) { option in
                    if option.isPrimary {
                        Button(option.title) { model.choose(option.choice) }
                            .buttonStyle(.borderedProminent)
                            // With a warning, Return must not accept it by accident.
                            .keyboardShortcut(hasWarnings ? nil : .defaultAction)
                    } else {
                        Button(option.title) { model.choose(option.choice) }
                    }
                }
            }
        }
    }
}

private struct FolderListView: View {
    var listing: FolderListing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(listing.summary).font(.callout.weight(.medium))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(listing.shown, id: \.self) { entry in
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if listing.hiddenCount > 0 {
                        Text("… and \(listing.hiddenCount) more")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .frame(height: 180)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(FolderListing.leftOutNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if listing.servedAsWebsite {
                Label("This folder has an index.html, so it opens as a website.", systemImage: "globe")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hosting the window

/// Owns the window. SwiftUI scenes can't be opened from outside a view (Finder requests arrive
/// through AppKit), so this window is plain AppKit around a SwiftUI view.
@MainActor
final class PublishWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<PublishWindowView>?
    private var closingFromCode = false
    private var resizeTask: Task<Void, Never>?

    func sync(with model: AppModel, suppressed: Bool) {
        let wanted = model.session.wantsWindow || model.notice != nil || model.batch != nil
        if wanted && !suppressed {
            show(model)
            resizeSoon()
        } else if !wanted {
            close()
        }
    }

    private func show(_ model: AppModel) {
        if window == nil {
            let controller = NSHostingController(rootView: PublishWindowView(model: model))
            // The window must not follow SwiftUI's ideal size on its own: frame and layout then
            // feed each other, and during a drop animation AppKit gives up after ~50 constraint
            // passes and throws (crash 2026-11-16, window 500 x 146). The size is set explicitly
            // in resizeSoon() once the content has settled.
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "Upload the File"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(Self.settledSize(of: controller.view) ?? NSSize(width: 500, height: 200))
            window.center()
            self.window = window
            self.hosting = controller
        }
        guard let window else { return }
        if !window.isVisible {
            AppActivation.bringToFront()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Follows the content's height after it has settled (100 ms), only when it changed by more
    /// than a point; the same rule as the popover (PopoverSizing).
    private func resizeSoon() {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(PopoverSizing.settleMilliseconds))
            guard !Task.isCancelled, let self, let window = self.window, let view = self.hosting?.view,
                  let wanted = Self.settledSize(of: view)
            else { return }
            let current = window.contentRect(forFrameRect: window.frame).size
            guard abs(wanted.height - current.height) > PopoverSizing.changeThreshold
                    || abs(wanted.width - current.width) > PopoverSizing.changeThreshold
            else { return }
            // Keep the top edge where it is, as a sheet-like window does.
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: wanted))
            frame.origin.x = window.frame.minX
            frame.origin.y = window.frame.maxY - frame.height
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private static func settledSize(of view: NSView) -> NSSize? {
        let size = view.fittingSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    private func close() {
        resizeTask?.cancel()
        guard let window, window.isVisible else { return }
        closingFromCode = true
        window.close()
        closingFromCode = false
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingFromCode else { return }
        AppModel.shared.publishWindowWasClosed()
    }
}
