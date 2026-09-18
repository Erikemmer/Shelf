import ShelfCore
import SlateKit
import SwiftUI

/// What is on the device: every book file Shelf can see, which library book it
/// is, and — on a Kobo — how far its owner has read.
///
/// It is also the only place `Delete from Device…` can be reached from, and
/// that is deliberate: choosing files is part of deleting them, and a menu item
/// that deleted "the selection" would be a menu item whose meaning depends on
/// which pane had the keyboard.
struct DeviceContentsSheet: View {
    @Environment(LibraryModel.self) private var model

    /// Ticked by hand. Nothing starts ticked — the opposite of the orphan
    /// sheet, where everything found is debris by definition. Here every file
    /// is somebody's book.
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let device = model.devices.selectedDevice {
                content(device)
            } else {
                Text(Loc.string("No device is connected.")).foregroundStyle(Slate.textSecondary)
                HStack {
                    Spacer()
                    Button(Loc.string("Close")) { model.isDeviceContentsSheetPresented = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .background(Slate.windowBackground)
    }

    @ViewBuilder
    private func content(_ device: ConnectedDevice) -> some View {
        let files = model.devices.files(on: device)
        Text(Loc.string("On “%@”", device.name))
            .font(.title3)
            .foregroundStyle(Slate.textPrimary)
        Text(model.devices.subtitle(for: device))
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)

        if files.isEmpty {
            Text(Loc.string("No book files Shelf recognises are on this device."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(files) { file in row(file, device: device) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }

        buttons(files: files, device: device)
    }

    private func row(_ file: DeviceFile, device: ConnectedDevice) -> some View {
        Toggle(
            isOn: Binding(
                get: { chosen.contains(file.path) },
                set: { isOn in
                    if isOn {
                        chosen.insert(file.path)
                    } else {
                        chosen.remove(file.path)
                    }
                })
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.caption).foregroundStyle(Slate.textPrimary).lineLimit(1)
                Text(detail(for: file, device: device))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The second line: the size, how the file was matched to a book, and what
    /// a Kobo says about it.
    ///
    /// "sent by Shelf" and "matched by name" are different claims and the row
    /// says which one this is — a file matched by its name is a guess, and the
    /// delete confirmation shows the same word.
    private func detail(for file: DeviceFile, device: ConnectedDevice) -> String {
        var parts = [ByteCount.format(file.byteSize)]
        if let match = file.matchedBy { parts.append(Loc.core(match.label)) }
        if device.profile.readBack == .kobo,
            let reading = model.devices.readingByDevice[device.id]?.book(at: file.path)
        {
            parts.append(
                reading.percentRead > 0
                    ? Loc.string("%1$@ · %2$lld%%", Loc.core(reading.status.label), reading.percentRead)
                    : Loc.core(reading.status.label))
            if !reading.shelves.isEmpty {
                parts.append(
                    Loc.string(
                        "on the device's shelves: %@",
                        reading.shelves.joined(separator: ", ")))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func buttons(files: [DeviceFile], device: ConnectedDevice) -> some View {
        HStack {
            Button(chosen.count == files.count ? Loc.string("Select None") : Loc.string("Select All")) {
                chosen = chosen.count == files.count ? [] : Set(files.map(\.path))
            }
            .disabled(files.isEmpty)
            Spacer()
            Button(Loc.string("Close")) { model.isDeviceContentsSheetPresented = false }
                .keyboardShortcut(.cancelAction)
            // The only route to deleting. It opens the confirmation; it does
            // not delete (ADR 0014).
            Button(Loc.string("Delete from Device…")) {
                model.askToDeleteFromDevice(files.filter { chosen.contains($0.path) }, on: device)
            }
            .disabled(chosen.isEmpty || model.devices.phase.isRunning)
        }
    }
}
