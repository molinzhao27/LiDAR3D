import ARKit
import ScanCore
import SwiftUI

struct ScanDetailView: View {
    let scan: ScanRecord

    private enum Display: String, CaseIterable, Identifiable {
        case mesh = "Mesh"
        case points = "Points"
        var id: String { rawValue }
    }

    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var display: Display = .mesh
    @State private var mesh: Mesh?
    @State private var points: Mesh?
    @State private var unlit = true
    @State private var showingAR = false
    @State private var confirmingDelete = false
    @State private var loadError: String?

    private var current: Mesh? { display == .mesh ? mesh : points }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let current {
                    ModelView(mesh: current, unlit: unlit)
                } else if let loadError {
                    Text(loadError).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.secondarySystemBackground))

            VStack(spacing: 12) {
                if scan.hasMesh && scan.hasPoints {
                    Picker("Show", selection: $display) {
                        ForEach(Display.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    Toggle("Shaded", isOn: Binding(get: { !unlit }, set: { unlit = !$0 }))
                        .disabled(current?.isPointCloud ?? true)
                    Spacer()
                    Text(stats).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    showingAR = true
                } label: {
                    Label("View in AR", systemImage: "arkit").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(current == nil || !ARWorldTrackingConfiguration.isSupported)
            }
            .padding()
        }
        .navigationTitle(scan.info.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(items: scan.exports) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Delete this scan?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(scan)
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $showingAR) {
            if let current { ARPlacementView(mesh: current) }
        }
        .task { await load() }
    }

    private var stats: String {
        guard let current else { return "" }
        if current.isPointCloud { return "\(current.vertexCount.formatted()) points" }
        return "\(current.triangleCount.formatted()) triangles"
    }

    private func load() async {
        let scan = self.scan
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (Mesh?, Mesh?) in
                let mesh: Mesh? = try scan.hasMesh ? PLY.decode(Data(contentsOf: scan.meshPLY)) : nil
                let points: Mesh? = try scan.hasPoints ? PLY.decode(Data(contentsOf: scan.pointsPLY)) : nil
                return (mesh, points)
            }.value
            mesh = loaded.0
            points = loaded.1
            if mesh == nil { display = .points }
            if mesh == nil && points == nil { loadError = "This scan has no model files." }
        } catch {
            loadError = "Couldn't open this scan: \(error.localizedDescription)"
        }
    }
}
