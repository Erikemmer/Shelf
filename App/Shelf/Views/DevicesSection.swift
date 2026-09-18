import ShelfCore
import SlateKit
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar's *Devices* section: what is plugged in, how much room is left
/// on it, and how many of its books Shelf recognises (CONCEPT §8.1).
///
/// A device row is a **drop target**: dragging books onto it is one of the two
/// ways to send them, ⌘⇧S being the other. It is not a filter — clicking it
/// selects the device for the menu items rather than narrowing the grid, which
/// is why this section is its own view instead of a sixth case in
/// `SidebarView.rows(for:)`.
struct DevicesSection: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        Group {
            SlateSidebarSection(SidebarSection.devices.rawValue)
            if model.devices.devices.isEmpty {
                Text(SidebarSection.devices.emptyNote)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            } else {
                ForEach(model.devices.devices) { device in
                    row(for: device)
                }
            }
        }
    }

    private func row(for device: ConnectedDevice) -> some View {
        SlateSidebarRow(
            icon: icon(for: device),
            count: nil,
            isActive: model.devices.selectedDeviceID == device.id,
            help: "\(device.profile.name) at \(device.volume.url.path) — drop books here to send them",
            title: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .foregroundStyle(Slate.textPrimary)
                        .lineLimit(1)
                    // Free space is what somebody checks before dragging 200
                    // books onto a card, so it is on the row rather than
                    // behind a click.
                    Text(model.devices.subtitle(for: device))
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .lineLimit(1)
                }
            },
            accessory: {
                Button {
                    model.devices.eject(device)
                } label: {
                    Image(systemName: "eject.fill").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Slate.textSecondary)
                // Never during a transfer (CONCEPT §8.4). The model refuses it
                // as well — this only keeps a disabled thing from looking
                // available.
                .disabled(model.devices.phase.isRunning)
                .help(
                    model.devices.phase.isRunning
                        ? "A transfer is running — it has to finish or be stopped first"
                        : "Eject “\(device.name)”"
                )
                .accessibilityLabel("Eject \(device.name)")
            },
            action: { _ in model.devices.selectedDeviceID = device.id }
        )
        // Books dragged onto the device. The same payload the grid drags
        // (a book's id as text), so one drop target serves both views.
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return false }
            model.sendToDevice(bookIDs: Set(ids), device: device)
            return true
        }
        .contextMenu {
            Button("Send Selected Books to “\(device.name)”") { model.sendSelectionToDevice(device) }
                .disabled(model.selection.isEmpty)
            Button("Show What Is on “\(device.name)”…") { model.showDeviceContents(device) }
            Divider()
            Button("Eject “\(device.name)”") { model.devices.eject(device) }
                .disabled(model.devices.phase.isRunning)
            if device.wasChosenByHand {
                Button("Stop Treating This as a Device") {
                    model.devices.forgetManualAssignment(for: device)
                }
            }
        }
    }

    /// A device the person vouched for by hand is drawn differently, because it
    /// is a different claim: Shelf recognised the others.
    private func icon(for device: ConnectedDevice) -> String {
        device.wasChosenByHand ? "externaldrive.badge.questionmark" : "ipad.and.iphone"
    }
}
