import AppKit
import ShelfCore
import SlateKit
import SwiftUI
import UniformTypeIdentifiers

/// Three columns, in the spirit of Final Cut Pro and of Selector:
/// Sidebar (left) · Cover grid (centre) · Inspector (right).
struct ContentView: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        Group {
            // Without a library the three panels would all be empty; show the
            // way in instead of three grey boxes.
            if model.library == nil { WelcomeView() } else { workspace }
        }
        .background(Slate.windowBackground)
        // "My Library — Shelf" while one is open, plain "Shelf" before.
        .navigationTitle(model.library.map { "\($0.name) — Shelf" } ?? "Shelf")
        .toolbar { toolbarContent }
        .overlay(alignment: .top) { banners }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FolderDrop.handle(providers, into: model)
        }
        .sheet(
            isPresented: Binding(
                get: { model.isImportSheetPresented },
                set: { model.isImportSheetPresented = $0 })
        ) {
            ImportSheet().environment(model)
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Theme.sidebarWidth)
            Rectangle().fill(Slate.separator).frame(width: 1)
            CoverGridView()
            if model.isInspectorShown {
                Rectangle().fill(Slate.separator).frame(width: 1)
                InspectorView()
                    .frame(width: Theme.inspectorWidth)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label("Open Library", systemImage: "folder")
            }
            .help("Open a Shelf library (⌘O)")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.presentAddBooksPanel()
            } label: {
                Label("Add Books", systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help("Add books or a folder of books (⌘I)")
            .disabled(model.library == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(
                isOn: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })
            ) {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .labelStyle(.titleAndIcon)
            .help(model.isInspectorShown ? "Hide the Inspector" : "Show the Inspector")
            .disabled(model.library == nil)
        }
    }

    /// An error, and the warning a synced library gets. Both dismissible: a
    /// banner nobody can close is a banner that hides the app.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 4) {
            if let message = model.errorMessage {
                SlateBanner(message)
                    .onTapGesture { model.dismissError() }
                    .help("Click to dismiss")
            }
            if let warning = model.syncWarning {
                SlateBanner(warning, tint: Slate.accent.opacity(0.85))
                    .onTapGesture { model.dismissSyncWarning() }
                    .help("Click to dismiss")
            }
        }
        .padding(.horizontal, 20)
    }
}
