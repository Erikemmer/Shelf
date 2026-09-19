import ShelfCore
import SlateKit
import SwiftUI

/// `File ▸ Export Library…` — the library written out as an ordinary folder of
/// files that will still be readable when this program is not.
///
/// Three presets, because the switches are the *how* and the presets are the
/// *why*: keep everything, hand somebody the books, or go back to Calibre.
/// Every switch stays visible and changeable underneath — a preset is a
/// starting point, not a mode.
///
/// The sentence under "Just the books" is the reason this sheet is worth
/// writing carefully. Somebody exporting their library to give to a friend has
/// to be told, before they press anything, that the rating, the read status,
/// the tags and the shelves are not coming along.
struct ExportSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text(
                model.exportsSelectionOnly
                    ? Loc.string("Export Selected Books…") : Loc.string("Export Library…")
            )
            .font(.title3)
            .foregroundStyle(Slate.textPrimary)

            switch model.exportPhase {
            case .choosing, .planning, .ready, .none:
                form
            case .running(let progress):
                running(progress)
            case .done(let report):
                finished(report)
            }

            buttons
        }
        .padding(20)
        .frame(width: 620)
        .background(Slate.windowBackground)
    }

    // MARK: The form

    @ViewBuilder
    private var form: some View {
        @Bindable var model = model
        destinationRow
        presetRow
        Text(Loc.core(preset?.explanation ?? ExportPreset.archive.explanation))
            .font(.caption)
            .foregroundStyle(preset == .booksOnly ? Slate.accent : Slate.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        Divider()
        detailRows
        outcome
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Text(Loc.string("Into"))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
            Text(model.exportDestination?.path ?? Loc.string("No folder chosen yet"))
                .font(.caption)
                .foregroundStyle(Slate.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button(Loc.string("Choose…")) { chooseDestination() }
        }
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(ExportPreset.allCases, id: \.self) { candidate in
                Button(Loc.core(candidate.label)) {
                    model.exportOptions = candidate.options
                    replan()
                }
                .buttonStyle(.bordered)
                .tint(preset == candidate ? Slate.accent : Slate.textSecondary)
            }
        }
    }

    private var preset: ExportPreset? { ExportPreset.matching(model.exportOptions) }

    @ViewBuilder
    private var detailRows: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            // Formats. "All" is a state of its own and not every box ticked:
            // a format added to Shelf later should go without anybody
            // re-ticking anything.
            HStack(spacing: 10) {
                Text(Loc.string("Formats"))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                Toggle(
                    Loc.string("All"),
                    isOn: Binding(
                        get: { model.exportOptions.formats == nil },
                        set: { on in
                            model.exportOptions.formats = on ? nil : Set(chosenFormats)
                            replan()
                        })
                )
                .toggleStyle(.checkbox)
                ForEach(BookFileFormat.allCases.sorted(), id: \.self) { format in
                    Toggle(
                        format.label,
                        isOn: Binding(
                            get: { model.exportOptions.includes(format) },
                            set: { on in
                                var chosen = model.exportOptions.formats ?? Set(chosenFormats)
                                if on { chosen.insert(format) } else { chosen.remove(format) }
                                model.exportOptions.formats = chosen
                                replan()
                            })
                    )
                    .toggleStyle(.checkbox)
                    .disabled(model.exportOptions.formats == nil)
                }
            }

            Picker(
                Loc.string("Structure"),
                selection: Binding(
                    get: { model.exportOptions.structure },
                    set: {
                        model.exportOptions.structure = $0
                        replan()
                    })
            ) {
                ForEach(ExportOptions.Structure.allCases, id: \.self) { structure in
                    Text(Loc.core(structure.label)).tag(structure)
                }
            }
            .pickerStyle(.radioGroup)

            HStack(spacing: 8) {
                Text(Loc.string("Name pattern"))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
                TextField(
                    ExportOptions.defaultNamePattern,
                    text: Binding(
                        get: { model.exportOptions.namePattern },
                        set: {
                            model.exportOptions.namePattern = $0
                            replan()
                        })
                )
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Loc.string("Name pattern"))
            }
            Text(tokenHelp)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)

            HStack(spacing: 14) {
                Toggle(
                    Loc.string("cover.jpg"),
                    isOn: Binding(
                        get: { model.exportOptions.includesCover },
                        set: {
                            model.exportOptions.includesCover = $0
                            replan()
                        })
                )
                .toggleStyle(.checkbox)
                Toggle(
                    Loc.string("metadata.opf"),
                    isOn: Binding(
                        get: { model.exportOptions.includesOPF },
                        set: {
                            model.exportOptions.includesOPF = $0
                            replan()
                        })
                )
                .toggleStyle(.checkbox)
                Toggle(
                    Loc.string("Hard links where possible"),
                    isOn: Binding(
                        get: { model.exportOptions.prefersHardLinks },
                        set: {
                            model.exportOptions.prefersHardLinks = $0
                            replan()
                        })
                )
                .toggleStyle(.checkbox)
                .help(
                    Loc.string(
                        "On the same disk a link costs no space at all. Safe because Shelf never "
                            + "writes a book file. Across disks it is a copy."))
            }
        }
    }

    private var tokenHelp: String {
        NamePattern.Token.allCases
            .map { "\($0.rawValue) \(Loc.core($0.explanation))" }
            .joined(separator: " · ")
    }

    private var chosenFormats: [BookFileFormat] { BookFileFormat.allCases }

    @ViewBuilder
    private var outcome: some View {
        if let refusal = model.exportOptions.refusal {
            Text(Loc.core(refusal))
                .font(.caption)
                .foregroundStyle(Slate.accent)
        } else if case .ready(let plan) = model.exportPhase {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.summary())
                    .font(.caption)
                    .foregroundStyle(Slate.textPrimary)
                if plan.optionsChanged {
                    Text(
                        Loc.string(
                            "The last export into this folder used different options, so all of "
                                + "it is written again.")
                    )
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                }
                if !plan.stale.isEmpty {
                    Text(
                        Loc.count(
                            "%lld files an earlier export wrote are no longer wanted and will be taken away",
                            plan.stale.count)
                    )
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
                }
            }
        } else if case .planning = model.exportPhase {
            ProgressView().progressViewStyle(.linear)
        }
    }

    // MARK: Running and finished

    private func running(_ progress: ExportRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fractionDone).progressViewStyle(.linear)
            Text(
                Loc.string(
                    "%1$@ of %2$@ · %3$@", "\(progress.filesDone)", "\(progress.filesTotal)",
                    progress.currentTitle)
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .lineLimit(1)
        }
    }

    private func finished(_ report: ExportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.headline)
                .foregroundStyle(Slate.textPrimary)
            Text(
                Loc.string(
                    "%1$@ copied · %2$@ hard links", Loc.size(report.copiedBytes),
                    "\(report.hardLinkCount)")
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            if !report.options.includesOPF {
                Text(
                    Loc.string(
                        "The rating, the read status, the tags and the shelves are not in this "
                            + "folder. They live in the metadata.opf, which was not written.")
                )
                .font(.caption)
                .foregroundStyle(Slate.accent)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(Loc.string("The full report is in Shelf-Export-Report.txt in that folder."))
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            if case .done = model.exportPhase, let destination = model.exportDestination {
                Button(Loc.string("Show in Finder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: destination.path)
                }
            }
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.exportPhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.exportPhase {
                Button(Loc.string("Export")) { model.runExport(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.isEmpty && plan.stale.isEmpty)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.exportPhase { return true }
        return false
    }

    // MARK: Choosing where

    /// An open panel, not a save panel: the sandbox grants write access to what
    /// a person picks in one, and an export writes a tree rather than a file.
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = Loc.string("Export Here")
        panel.message = Loc.string("Choose an empty folder, or one an earlier export wrote.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDestination = url
        replan()
    }

    private func replan() {
        guard model.exportDestination != nil, model.exportOptions.refusal == nil else { return }
        Task { await model.planExport() }
    }
}
