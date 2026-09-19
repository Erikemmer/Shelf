import ShelfCore
import SlateKit
import SwiftUI

/// The counting protocol for a transfer, and the button that acts on it.
///
/// Nothing is copied until the person has seen these numbers: how many books,
/// in which format each one goes, which ones **cannot** be sent and why, and
/// how much room it takes. What is confirmed here is the exact `TransferPlan`
/// the runner is handed — the same rule the import sheet follows, and for the
/// same reason.
struct SendToDeviceSheet: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            if let device = model.devices.selectedDevice {
                content(device)
            } else {
                Text(Loc.string("No device is connected.")).foregroundStyle(Slate.textSecondary)
            }
            buttons
        }
        .padding(20)
        .frame(width: 560)
        .background(Slate.windowBackground)
    }

    private var title: String {
        switch model.devices.phase {
        case .finished: return Loc.string("Sent")
        case .running: return Loc.string("Sending…")
        default: return Loc.string("Send to Device")
        }
    }

    @ViewBuilder
    private func content(_ device: ConnectedDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(device)
            switch model.devices.phase {
            case .idle, .planning:
                SlateStatusBar(Loc.string("Working out what would be sent"))
            case .ready(let plan):
                plannedView(plan, device: device)
            case .running(let progress):
                runningView(progress)
            case .finished(let report):
                finishedView(report)
            }
            if let message = model.devices.errorMessage {
                SlateBanner(message).onTapGesture { model.devices.dismissError() }
            }
        }
    }

    private func header(_ device: ConnectedDevice) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(device.name) — \(device.profile.name)")
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
            if let free = device.volume.freeBytes {
                Text(Loc.string("%@ free", Loc.size(free))).font(.caption2).foregroundStyle(Slate.textSecondary)
            }
            // The one sentence a profile has to say about itself — "a Kindle
            // does not read EPUB over USB". Shown before the list rather than
            // beside a book, because it explains the whole of why some books
            // are in the second list.
            if let note = device.profile.note {
                Text(note).font(.caption2).foregroundStyle(Slate.textSecondary)
            }
        }
    }

    // MARK: Ready

    @ViewBuilder
    private func plannedView(_ plan: TransferPlan, device: ConnectedDevice) -> some View {
        Text(Summaries.line(for: plan))
            .font(.callout)
            .foregroundStyle(Slate.textPrimary)

        if !plan.fits(freeBytes: device.volume.freeBytes) {
            SlateBanner(
                Loc.string(
                    "Not enough room: %1$@ needed, %2$@ free.", Loc.size(plan.requiredBytes),
                    Loc.size(device.volume.freeBytes ?? 0)))
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !plan.operations.isEmpty {
                    Text(Loc.string("Will be sent")).font(.caption).foregroundStyle(Slate.textSecondary)
                    ForEach(plan.operations) { operation in
                        row(operation.title, detail: "\(operation.format.label) · \(operation.destinationPath)")
                    }
                }
                // Named, never only counted: "2 cannot be sent" is exactly the
                // number somebody wants the two titles for.
                ForEach(SkippedTransfer.Reason.allCases, id: \.self) { reason in
                    let group = plan.skipped(for: reason)
                    if !group.isEmpty {
                        Text(Loc.core(reason.label)).font(.caption).foregroundStyle(Slate.textSecondary)
                            .padding(.top, 4)
                        ForEach(group) { skipped in row(skipped.title, detail: nil) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    private func row(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(Slate.textPrimary).lineLimit(1)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(Slate.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Running and finished

    private func runningView(_ progress: TransferRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress.fractionDone)
            Text(
                Loc.string(
                    "%1$@ of %2$@ · %3$@", Loc.number(progress.filesDone),
                    Loc.number(progress.filesTotal), progress.currentTitle)
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .lineLimit(1)
            Text(Loc.string("Every file is read back off the device and checked before it counts."))
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private func finishedView(_ report: TransferReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The line CONCEPT §8.2 asks for, word for word.
            Text(Summaries.line(for: report)).font(.callout).foregroundStyle(Slate.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.sent, id: \.path) { sent in
                        row(sent.title, detail: "\(sent.format.label) · \(sent.path)")
                    }
                    ForEach(report.failures, id: \.path) { failure in
                        row(failure.title, detail: failure.message)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Text(Loc.string("The report is on the device, in .shelf/%@.", TransferReport.fileName))
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch model.devices.phase {
            case .running:
                // Stopping is safe at any moment: what is verified stays, and
                // nothing half-written is left behind.
                Button(Loc.string("Stop")) { model.devices.cancelTransfer() }
            case .ready(let plan):
                Button(Loc.string("Cancel")) { model.devices.closeSendSheet() }
                Button(Loc.string("Send")) { model.runTransfer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty)
            default:
                Button(Loc.string("Close")) { model.devices.closeSendSheet() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
