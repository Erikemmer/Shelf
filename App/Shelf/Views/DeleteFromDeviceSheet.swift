import ShelfCore
import SlateKit
import SwiftUI

/// `Device ▸ Delete from Device…` — the confirmation that names every file
/// ([ADR 0014](../../../docs/adr/0014-deleting-on-a-device-needs-a-named-confirmation.md),
/// CONCEPT §8.3).
///
/// Two things about this sheet are the whole of it. The list is **not
/// summarised and not truncated**: a dialog saying "Delete 214 files?" names
/// nothing and can be agreed to by accident, and these are somebody's books.
/// And it says what will *not* happen as plainly as what will, because the fear
/// this dialog has to answer is "does this take them out of my library too".
///
/// There is no other route to deleting on a device. Not a sync, not a
/// reconnect, not a transfer that tidies up after itself.
struct DeleteFromDeviceSheet: View {
    @Environment(LibraryModel.self) private var model
    /// Ticked by hand, once, before the button does anything. A second
    /// deliberate act for the one irreversible thing in the app.
    @State private var hasUnderstood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let outcome = model.devices.deleteOutcome {
                done(outcome)
            } else if let confirmation = model.devices.deleteConfirmation {
                asking(confirmation)
            } else {
                Text(Loc.string("Nothing is selected on the device.")).foregroundStyle(Slate.textSecondary)
                HStack {
                    Spacer()
                    Button(Loc.string("Close")) { model.devices.closeDeleteSheet() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .background(Slate.windowBackground)
    }

    @ViewBuilder
    private func asking(_ confirmation: DeviceDeletion.Confirmation) -> some View {
        Text(confirmation.question)
            .font(.title3)
            .foregroundStyle(Slate.textPrimary)
        Text(confirmation.explanation)
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)

        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // Every one of them. `ForEach` over the whole list on purpose:
                // a cap here would be the summarising this sheet exists to
                // refuse.
                ForEach(Array(confirmation.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(Slate.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 300)

        Toggle(
            Loc.string("I have read the list above"),
            isOn: $hasUnderstood
        )
        .font(.caption)
        .foregroundStyle(Slate.textSecondary)

        HStack {
            Spacer()
            Button(Loc.string("Cancel")) { model.devices.closeDeleteSheet() }
                .keyboardShortcut(.cancelAction)
            Button(Loc.string("Delete from Device")) { model.confirmDeleteFromDevice() }
                .disabled(!hasUnderstood)
        }
    }

    @ViewBuilder
    private func done(_ outcome: DeviceDeletion.Outcome) -> some View {
        Text(Loc.string("Deleted")).font(.title3).foregroundStyle(Slate.textPrimary)
        Text(outcome.summary).font(.caption).foregroundStyle(Slate.textSecondary)
        if !outcome.failed.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(outcome.failed.keys.sorted(), id: \.self) { path in
                        Text(verbatim: "\(path): \(outcome.failed[path] ?? "")")
                            .font(.caption2)
                            .foregroundStyle(Slate.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
        Text(Loc.string("Your library was not touched.")).font(.caption2).foregroundStyle(Slate.textSecondary)
        HStack {
            Spacer()
            Button(Loc.string("Close")) { model.devices.closeDeleteSheet() }.keyboardShortcut(.defaultAction)
        }
    }
}
