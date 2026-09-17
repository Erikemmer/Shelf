import ShelfCore
import SlateKit
import SwiftUI

/// `Library ▸ Find Orphaned Folders…` — the folders in the library that no book
/// points at, and the one confirmed way to be rid of them.
///
/// These are what an import that was killed leaves behind: `ImportRunner`
/// writes a book's folder, file, cover and OPF before the book reaches the
/// index, and the index is written every 200 books, so a run that dies between
/// two of those writes leaves finished folders nothing knows about.
///
/// The sheet is deliberately two steps. The first lists what was found; the
/// second names **every file** that would move, and only then is there a button
/// that moves anything. That is the same rule deleting on a device follows
/// (CONCEPT §8.3), and it is here for the same reason: Shelf's belief that a
/// folder is debris is a belief, and the person whose books these are is the
/// one who gets to check it. Nothing is deleted either way — the folders go to
/// the Trash, where they can be dragged back out.
struct OrphanSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Which folders the user has left ticked. Everything found starts ticked;
    /// a folder is only ever acted on because it is in here.
    @State private var chosen: Set<String> = []
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isConfirming ? "Move These to the Trash?" : "Orphaned Folders")
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            if model.isScanningForOrphans {
                scanning
            } else if model.orphanedFolders.isEmpty {
                nothingFound
            } else if isConfirming {
                confirmation
            } else {
                listing
            }

            buttons
        }
        .padding(20)
        .frame(width: 560)
        .background(Slate.windowBackground)
        // Everything found starts ticked, but only what is still there: a
        // second scan after a move must not leave a tick on a folder that has
        // gone.
        .onChange(of: model.orphanedFolders.map(\.path)) { _, paths in
            chosen = chosen.intersection(paths).union(paths)
            if paths.isEmpty { isConfirming = false }
        }
        .onAppear { chosen = Set(model.orphanedFolders.map(\.path)) }
    }

    // MARK: States

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView().progressViewStyle(.linear)
            Text("Reading the library's folders. Nothing is being changed.")
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private var nothingFound: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every folder in this library belongs to a book.")
                .foregroundStyle(Slate.textPrimary)
            Text(
                "Orphans appear when an import is killed part-way through. "
                    + "A resumed import takes its own back by itself; this is for what is left."
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
        }
    }

    private var listing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "\(model.orphanedFolders.count) folder(s) hold files that no book in this library "
                    + "points at — \(ByteCount.format(totalBytes)) in all."
            )
            .foregroundStyle(Slate.textPrimary)

            Text(
                "They are usually what an import that was interrupted left behind. "
                    + "Nothing has been changed, and nothing will be until you say so."
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.orphanedFolders) { folder in
                        row(folder)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func row(_ folder: OrphanedFolder) -> some View {
        Toggle(
            isOn: Binding(
                get: { chosen.contains(folder.path) },
                set: { on in
                    if on { chosen.insert(folder.path) } else { chosen.remove(folder.path) }
                })
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.title ?? folder.path)
                    .font(.callout)
                    .foregroundStyle(Slate.textPrimary)
                    .lineLimit(1)
                Text(folder.path)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A folder that still holds a book file is a different thing to
                // be told about than one holding a stray cover, so it says so
                // rather than making the two look alike.
                Text(
                    "\(folder.files.count) file(s), \(ByteCount.format(folder.byteSize))"
                        + (folder.holdsABook ? " · holds a book file" : "")
                        + (folder.bookID == nil ? " · no metadata.opf" : "")
                )
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    /// The step the rule actually asks for: every file, by name, before
    /// anything moves.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(chosenFolders.count) folder(s), \(chosenFileCount) file(s), \(ByteCount.format(chosenBytes))")
                .foregroundStyle(Slate.textPrimary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chosenFolders) { folder in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.path)
                                .font(.caption)
                                .foregroundStyle(Slate.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ForEach(folder.files, id: \.self) { file in
                                Text("    \(file)")
                                    .font(.caption2)
                                    .foregroundStyle(Slate.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)

            Text("They go to the Trash, not away: you can put any of them back from there.")
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            if isConfirming {
                SlateSecondaryButton("Back") { isConfirming = false }
                SlatePrimaryButton("Move \(chosenFolders.count) Folder(s) to Trash") {
                    let folders = chosenFolders
                    Task {
                        await model.trashOrphanedFolders(folders)
                        isConfirming = false
                    }
                }
                .disabled(chosenFolders.isEmpty)
            } else {
                SlateSecondaryButton("Done") {
                    model.isOrphanSheetPresented = false
                    dismiss()
                }
                if !model.orphanedFolders.isEmpty {
                    SlatePrimaryButton("Move to Trash…") { isConfirming = true }
                        .disabled(chosenFolders.isEmpty || model.isScanningForOrphans)
                }
            }
        }
    }

    // MARK: What is ticked

    private var chosenFolders: [OrphanedFolder] {
        model.orphanedFolders.filter { chosen.contains($0.path) }
    }
    private var chosenFileCount: Int { chosenFolders.reduce(0) { $0 + $1.files.count } }
    private var chosenBytes: Int64 { chosenFolders.reduce(0) { $0 + $1.byteSize } }
    private var totalBytes: Int64 { model.orphanedFolders.reduce(0) { $0 + $1.byteSize } }
}
