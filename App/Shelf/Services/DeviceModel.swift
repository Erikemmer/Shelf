import AppKit
import Foundation
import Observation
import ShelfCore

/// The state of the Devices section: what is plugged in, what is on it, and how
/// far a transfer has got.
///
/// Its own model rather than part of `LibraryModel`, for the same reason
/// `ImportModel` is: a transfer survives the sheet being closed and reopened,
/// and a device appearing has nothing to do with the library's own state.
///
/// **Everything it decides, it decides in the core.** This type owns the
/// waiting, the tasks and the AppKit calls; which profile a volume is, what may
/// be sent to it, what each file is called there and what the confirmation says
/// are all `ShelfCore` values, tested without a device.
@MainActor
@Observable
final class DeviceModel {

    enum Phase: Equatable {
        case idle
        /// Working out what would be sent. Nothing is written.
        case planning
        case ready(TransferPlan)
        case running(TransferRunner.Progress)
        case finished(TransferReport)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    private(set) var devices: [ConnectedDevice] = []
    /// Which one the sheet and the menu items act on. The first one, until
    /// somebody clicks another.
    var selectedDeviceID: String?
    /// Book files found on each device, already matched to the library.
    private(set) var filesByDevice: [String: [DeviceFile]] = [:]
    /// What a Kobo says about how far its owner has read. Read only.
    private(set) var readingByDevice: [String: KoboReadingState.Reading] = [:]
    /// Every library book that is on any connected device — the grid's badge.
    private(set) var booksOnDevice: Set<UUID> = []

    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    /// Which books the pending transfer is for. Kept because the sheet is
    /// opened before the plan exists.
    private(set) var pendingTitles: [String] = []

    var isSendSheetPresented = false
    var isDeleteSheetPresented = false
    /// What the delete confirmation will say, built in the core.
    private(set) var deleteConfirmation: DeviceDeletion.Confirmation?
    private(set) var deleteOutcome: DeviceDeletion.Outcome?

    /// Volumes the user vouched for by hand: path → profile id. Kept for the
    /// life of the session only — a card that is not a reader this time may be
    /// one next time, and Shelf does not carry a claim about somebody's USB
    /// stick across launches.
    private(set) var manualAssignments: [String: String] = [:]

    @ObservationIgnored private let watcher = DeviceWatcher()
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var manifests: [String: DeviceManifest] = [:]

    // MARK: Watching

    func start() {
        watcher.start { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
        Task { await refresh() }
    }

    func stop() {
        watcher.stop()
        transferTask?.cancel()
    }

    /// Reads the mounted volumes again and, for each reader, what is on it.
    ///
    /// The library's own entries are passed in rather than held: they are
    /// `LibraryModel`'s and they change for reasons that have nothing to do
    /// with devices.
    func refresh(entries: [LibraryEntry] = []) async {
        let manual = manualAssignments
        let found = await Task.detached(priority: .userInitiated) {
            await MainActor.run { DeviceWatcher.connectedDevices(manual: manual) }
        }.value
        devices = found
        if selectedDeviceID == nil || !found.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = found.first?.id
        }
        if !entries.isEmpty || !found.isEmpty { await readContents(of: found, entries: entries) }
    }

    /// The listing, the manifest and — on a Kobo — the reading positions.
    ///
    /// Off the main actor: walking a 32 GB card and copying a database is not
    /// window work, and a reader plugged in while somebody is scrolling must
    /// not stutter the grid.
    private func readContents(of found: [ConnectedDevice], entries: [LibraryEntry]) async {
        let cache = Self.cacheDirectory
        let result = await Task.detached(priority: .utility) {
            () -> ([String: [DeviceFile]], [String: DeviceManifest], [String: KoboReadingState.Reading]) in
            var files: [String: [DeviceFile]] = [:]
            var manifests: [String: DeviceManifest] = [:]
            var readings: [String: KoboReadingState.Reading] = [:]
            for device in found {
                let manifest = DeviceManifest.read(fromVolume: device.volume.url, deviceID: device.profile.id)
                manifests[device.id] = manifest
                files[device.id] = DeviceContents.matched(
                    DeviceContents.list(on: device), to: entries, manifest: manifest,
                    profile: device.profile)
                // Only where the profile says there is something to read, and
                // never as anything but a read (CONCEPT §8.1).
                if device.profile.readBack == .kobo {
                    readings[device.id] = try? KoboReadingState().read(
                        volume: device.volume.url, cacheDirectory: cache)
                }
            }
            return (files, manifests, readings)
        }.value

        filesByDevice = result.0
        manifests = result.1
        readingByDevice = result.2
        booksOnDevice = Set(result.0.values.flatMap { DeviceContents.booksOnDevice($0) })
    }

    /// Where the copy of a device's database goes. Never under `~/Documents`,
    /// which is synced.
    static var cacheDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Shelf")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Asking it things

    var selectedDevice: ConnectedDevice? {
        devices.first { $0.id == selectedDeviceID } ?? devices.first
    }

    func device(id: String) -> ConnectedDevice? { devices.first { $0.id == id } }

    func files(on device: ConnectedDevice) -> [DeviceFile] { filesByDevice[device.id] ?? [] }

    /// How a device describes itself in the sidebar: "12 books · 4.2 GB free".
    func subtitle(for device: ConnectedDevice) -> String {
        var parts: [String] = []
        let count = files(on: device).count
        parts.append(Loc.count("%lld books", count))
        if let free = device.volume.freeBytes { parts.append(Loc.string("%@ free", Loc.size(free))) }
        return parts.joined(separator: " · ")
    }

    /// What a Kobo says about one book of the library, or nothing.
    func reading(of bookID: UUID) -> KoboReadingState.Book? {
        for device in devices where device.profile.readBack == .kobo {
            guard let reading = readingByDevice[device.id],
                let file = files(on: device).first(where: { $0.bookID == bookID })
            else { continue }
            if let book = reading.book(at: file.path) { return book }
        }
        return nil
    }

    // MARK: Treating a volume as a device by hand

    /// Volumes that are mounted and are not recognised as readers.
    var unrecognisedVolumes: [MountedVolume] {
        let known = Set(devices.map(\.id))
        return DeviceWatcher.mountedVolumes().filter { !known.contains($0.url.path) }
    }

    /// "Treat this volume as device…" — the way in when no marker matches
    /// (CONCEPT §8.1). It is remembered for this session and no longer.
    func treat(_ volume: MountedVolume, as profileID: String, entries: [LibraryEntry]) {
        manualAssignments[volume.url.path] = profileID
        selectedDeviceID = volume.url.path
        Task { await refresh(entries: entries) }
    }

    func forgetManualAssignment(for device: ConnectedDevice) {
        manualAssignments.removeValue(forKey: device.volume.url.path)
        Task { await refresh() }
    }

    // MARK: Sending

    /// Works out what would be sent. **Nothing is written.**
    func prepareTransfer(of entries: [LibraryEntry], to device: ConnectedDevice, libraryRoot: URL) async {
        guard !phase.isRunning else { return }
        errorMessage = nil
        pendingTitles = entries.map(\.book.title)
        phase = .planning
        isSendSheetPresented = true

        let manifest =
            manifests[device.id]
            ?? DeviceManifest.read(
                fromVolume: device.volume.url, deviceID: device.profile.id)
        let candidates = entries.map {
            TransferCandidate(
                entry: $0, folder: libraryRoot.appendingPathComponent($0.folder, isDirectory: true))
        }
        let plan = await Task.detached(priority: .userInitiated) {
            TransferPlanner.plan(candidates: candidates, device: device, manifest: manifest)
        }.value

        manifests[device.id] = manifest
        phase = .ready(plan)
    }

    /// Copies what the plan names, verifying every file on the device.
    func runTransfer(to device: ConnectedDevice, entries: [LibraryEntry]) {
        guard case .ready(let plan) = phase, !plan.isEmpty else { return }
        guard plan.fits(freeBytes: device.volume.freeBytes) else {
            errorMessage =
                Loc.string(
                    "Not enough room on “%1$@”: %2$@ needed, %3$@ free. Nothing was copied.",
                    device.name, Loc.size(plan.requiredBytes),
                    Loc.size(device.volume.freeBytes ?? 0))
            return
        }

        let manifest = manifests[device.id] ?? DeviceManifest(deviceID: device.profile.id)
        phase = .running(
            TransferRunner.Progress(
                filesDone: 0, filesTotal: plan.fileCount, bytesDone: 0, bytesTotal: plan.totalBytes,
                currentTitle: ""))

        // Built here rather than inline, so it captures `self` weakly once.
        // Nested inside the task's own `[weak self]` it would be a second
        // capture of the first one, which Swift 6 refuses.
        let onProgress: @Sendable (TransferRunner.Progress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard self.phase.isRunning else { return }
                self.phase = .running(progress)
            }
        }

        transferTask = Task { @MainActor [weak self] in
            let runner = TransferRunner(makeHasher: SHA256Hasher.factory)
            do {
                // `run` is not actor-isolated, so it leaves the main actor of
                // its own accord: the hashing and the copying happen on the
                // cooperative pool while this task waits here, and only the
                // progress and the result come back to the window.
                let outcome = try await runner.run(
                    .init(device: device, plan: plan, manifest: manifest), progress: onProgress)
                let volume = device.volume.url
                let report = outcome.report
                // Writing to the card is not window work either.
                await Task.detached { try? report.append(toVolume: volume) }.value

                guard let self else { return }
                self.manifests[device.id] = outcome.manifest
                self.phase = .finished(outcome.report)
                await self.refresh(entries: entries)
            } catch {
                guard let self else { return }
                self.errorMessage = Self.describe(error, device: device)
                self.phase = .ready(plan)
            }
        }
    }

    /// Stops a running transfer. What has already been verified stays on the
    /// device and in its manifest; nothing half-written is left behind.
    func cancelTransfer() {
        transferTask?.cancel()
    }

    func closeSendSheet() {
        isSendSheetPresented = false
        if !phase.isRunning { phase = .idle }
    }

    static func describe(_ error: any Error, device: ConnectedDevice) -> String {
        if case TransferRunner.Failure.notEnoughSpace(let needed, let available) = error {
            return Loc.string(
                "Not enough room on “%1$@”: %2$@ needed, %3$@ free. Nothing was copied.", device.name,
                Loc.size(needed), Loc.size(available))
        }
        return (error as NSError).localizedDescription
    }

    // MARK: Deleting on the device

    /// Builds the confirmation. **Nothing is deleted here** — this only writes
    /// the sentence and the list of names (ADR 0014).
    func askToDelete(_ files: [DeviceFile], on device: ConnectedDevice, entries: [LibraryEntry]) {
        guard !files.isEmpty, !phase.isRunning else { return }
        var titles: [UUID: String] = [:]
        for entry in entries { titles[entry.id] = entry.book.title }
        deleteOutcome = nil
        deleteConfirmation = DeviceDeletion.Confirmation(
            deviceName: device.name, files: files, titles: titles)
        isDeleteSheetPresented = true
    }

    /// Only ever reached from the confirmation's own button.
    func confirmDelete(on device: ConnectedDevice, entries: [LibraryEntry]) {
        guard let confirmation = deleteConfirmation else { return }
        var manifest = manifests[device.id] ?? DeviceManifest(deviceID: device.profile.id)
        let outcome = DeviceDeletion.delete(
            confirmation.files, fromVolume: device.volume.url, manifest: &manifest)
        try? manifest.write(toVolume: device.volume.url)
        manifests[device.id] = manifest
        deleteOutcome = outcome
        deleteConfirmation = nil
        Task { await refresh(entries: entries) }
    }

    func closeDeleteSheet() {
        isDeleteSheetPresented = false
        deleteConfirmation = nil
        deleteOutcome = nil
    }

    // MARK: Ejecting

    /// Never while a transfer is running (CONCEPT §8.4). The check is here
    /// rather than in the menu item, so every route to ejecting has it.
    func eject(_ device: ConnectedDevice) {
        guard !phase.isRunning else {
            errorMessage = Loc.string("“%@” is being written to. Stop the transfer first.", device.name)
            return
        }
        do {
            try DeviceWatcher.eject(device.volume.url)
            Task { await refresh() }
        } catch {
            errorMessage = Loc.string(
                "“%1$@” could not be ejected: %2$@", device.name,
                (error as NSError).localizedDescription)
        }
    }

    func dismissError() { errorMessage = nil }
}
