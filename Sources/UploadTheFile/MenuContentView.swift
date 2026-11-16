import AppKit
import SwiftUI
import UploadTheFileCore
import UptfKit

/// The menu bar popover: `PopoverSizing.width` wide. The status item controller calls
/// `model.windowDidOpen()` each time it opens.
///
/// The popover window does not follow this view's size by itself (that feedback loop crashed the
/// app while files were dropped on the list). The view lays out at its natural height for the fixed
/// width, whatever size the window is, and reports that height through `onContentHeight`; the
/// controller decides when the window follows (see `PopoverSizing`).
struct MenuContentView: View {
    var model: AppModel
    var onContentHeight: (Double) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.startupError {
                StartupErrorView(message: problem)
            } else {
                switch model.account {
                case .signedOut, .signingIn:
                    SignedOutView(model: model)
                case .signedIn:
                    SignedInView(model: model)
                }
            }
            Divider()
            FooterView(model: model)
        }
        .frame(width: PopoverSizing.width)
        // Natural height at this width, independent of the window: nothing in the window's size
        // can change what is measured here.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) { Double($0.size.height) } action: { onContentHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        // The popover is a drop target too (harmless: it is only open when the user put it there).
        // The menu bar icon is the one that works from Finder.
        .dropDestination(for: URL.self) { urls, _ in
            let files = DroppedItems.publishableFileURLs(from: urls)
            guard !files.isEmpty else { return false }
            // Not inside the drag callback, and not while AppKit still runs the drop animation
            // (CoreDragCommitDropAnimationTransaction spins the run loop): starting a publish can
            // open the confirmation window and change layout, which must wait until it is over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.publish(files) }
            return true
        } isTargeted: { model.isDropTargeted = $0 }
    }
}

// MARK: - Signed out

private struct SignedOutView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            BrandMark(height: 44)
                .padding(.top, 6)
            VStack(spacing: 4) {
                Text("Share a file with a link")
                    .font(.headline)
                Text("Publish files and folders from your Mac and send people the link. Sign in once with your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.account == .signingIn {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for your browser…").font(.callout)
                    }
                    Button("Cancel") { model.cancelSignIn() }
                        .controlSize(.regular)
                }
            } else {
                Button {
                    model.signIn()
                } label: {
                    Text("Sign In with Your Browser").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Text(model.signInNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.signInError {
                ErrorLine(text: error)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

private struct StartupErrorView: View {
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
            Text(message).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

struct ErrorLine: View {
    var text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                DismissButton(action: dismiss)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Signed in

private struct SignedInView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HeaderRow(model: model)
            if model.session.phase != .idle {
                SessionStatusView(model: model, onDismiss: model.session.isFinished ? { model.dismissSession() } : nil)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let error = model.errorMessage {
                ErrorLine(text: error) { model.errorMessage = nil }
            }
            PageListView(model: model)
        }
        .padding(12)
    }
}

/// The top of the signed-in popover: the app on the left, Choose File… on the right, and a line that
/// says where dropping works (the menu bar icon, not this popover).
private struct HeaderRow: View {
    var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let targeted = model.isDropTargeted
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BrandMark(height: 20)
                // Both titles are always laid out (one is invisible), so highlighting the drop
                // never changes the size of the header, and the popover never resizes during a drag.
                ZStack(alignment: .leading) {
                    Text("Upload the File").opacity(targeted ? 0 : 1)
                        .accessibilityHidden(targeted)
                    Text("Release to publish").opacity(targeted ? 1 : 0)
                        .accessibilityHidden(!targeted)
                }
                .font(.headline)
                .lineLimit(1)
                Spacer(minLength: 8)
                Button("Choose File…") { model.chooseAndPublish() }
                    .controlSize(.regular)
            }
            Text("Drop files on the menu bar icon, or right-click a file in Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(.horizontal, -4)
                .padding(.vertical, -6))
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: targeted)
    }
}

private struct PageListView: View {
    var model: AppModel

    var body: some View {
        switch model.listState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading your links…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let message):
            VStack(spacing: 8) {
                ErrorLine(text: message)
                Button("Try Again") { Task { await model.loadList() } }.controlSize(.small)
            }
        case .loaded:
            if model.rows.isEmpty {
                VStack(spacing: 4) {
                    Text("Nothing published yet").font(.callout.weight(.medium))
                    Text("Files and folders you publish appear here.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            PageRowView(model: model, row: row)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}

private struct PageRowView: View {
    var model: AppModel
    var row: PageRow
    @State private var hovering = false

    private var copied: Bool { model.copiedPageID == row.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Everything that is not a control lets clicks through to the row's own button behind
            // it, which copies the link.
            KindIcon(kind: row.page.kind)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)  // the row button says it
                detailLine
                if row.needsUpdate {
                    // The changed-file button gets a line of its own: beside the link there is
                    // no room for it, and the link must stay readable.
                    HStack(spacing: 8) {
                        Button(row.replaceTitle) { model.updateLink(row) }
                            .controlSize(.small)
                            .fixedSize()
                            .help("It changed on this Mac. Keeps the same link.")
                        Text("Changed on this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                CopyIconButton(copied: copied) { model.copyLink(row) }
                Menu {
                    Button("Open in Browser") { model.openInBrowser(row) }
                    Button("Copy Link") { model.copyLink(row) }
                    Button("Set Up Link…") {
                        OptionsWindowController.shared.open(pageID: row.id, appModel: model)
                    }
                    if row.canReveal {
                        Button("Show in Finder") { model.reveal(row) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        Task { _ = await model.delete(row) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(row.title)")
            }
            // Centred on the name and link lines, whatever else the row shows below them.
            .frame(height: 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
                // Clicking anywhere on the row that is not another control copies the link.
                Button {
                    model.copyLink(row)
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy Link")
                .accessibilityLabel("Copy link for \(row.title)")
                .accessibilityValue(row.subtitle)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Under the name: the link itself (a click opens it in the browser) and what it is, or, for a
    /// moment after a copy, the confirmation.
    @ViewBuilder private var detailLine: some View {
        if copied {
            Text("Link copied")
                .font(.caption)
                .foregroundStyle(Color.green)
                .lineLimit(1)
                .allowsHitTesting(false)
        } else {
            let link = OpenLinkButton(
                text: row.linkLabel, accessibilityName: "Open \(row.title) in your browser"
            ) { model.openInBrowser(row) }
            // The kind and size go first when the line is too narrow (a Replace button takes room).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    link
                    Text("· \(row.subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                link
            }
        }
    }
}

private struct KindIcon: View {
    var kind: String

    private var symbol: String {
        switch kind.lowercased() {
        case "site": return "globe"
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        case "mp4", "mov", "webm", "m4v": return "play.rectangle"
        case "mp3", "wav", "m4a", "aac": return "waveform"
        case "zip": return "doc.zipper"
        case "md", "txt": return "doc.text"
        default: return "doc"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(Color.accentColor)
            .frame(width: 30, height: 30)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Footer

private struct FooterView: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isSignedIn {
                Button { model.openDashboard() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text("Manage Files on \(model.siteLabel)")
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Opens your files on \(model.siteLabel) in your browser")
                .accessibilityLabel("Manage files on \(model.siteLabel) in your browser")
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                Divider()
            }
            accountRow
        }
    }

    private var accountRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isSignedIn ? "person.crop.circle" : "globe")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.isSignedIn ? "Signed in to \(model.siteLabel)" : model.siteLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if model.isSignedIn {
                Button("Sign Out") { model.signOut() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
