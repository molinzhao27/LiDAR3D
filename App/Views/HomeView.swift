import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var activeScanner: ScanKind?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(store.scans) { scan in
                            NavigationLink(value: scan) { ScanRow(scan: scan) }
                        }
                        .onDelete { offsets in
                            offsets.map { store.scans[$0] }.forEach(store.delete)
                        }
                    }
                }
            }
            .navigationTitle("Facet")
            .navigationDestination(for: ScanRecord.self) { scan in
                ScanDetailView(scan: scan)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingShare = true } label: { Label("Wi-Fi sharing", systemImage: "wifi") }
                }
            }
            .safeAreaInset(edge: .bottom) { scanButtons }
            .refreshable { await store.reload() }
        }
        .sheet(isPresented: $showingShare) { WiFiShareView() }
        .fullScreenCover(item: $activeScanner) { kind in
            switch kind {
            case .lidar: LiDARScanView()
            case .trueDepth: TrueDepthScanView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No scans yet").font(.title3.weight(.semibold))
            Text("Use the rear LiDAR for objects, people and rooms, or the front TrueDepth camera for faces and close-ups.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { activeScanner = .lidar } label: {
                    Label("LiDAR", systemImage: ScanKind.lidar.symbol).frame(maxWidth: .infinity)
                }
                .disabled(!LiDARScanner.isSupported)

                Button { activeScanner = .trueDepth } label: {
                    Label("TrueDepth", systemImage: ScanKind.trueDepth.symbol).frame(maxWidth: .infinity)
                }
                .disabled(!TrueDepthScanner.isSupported)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !LiDARScanner.isSupported && !TrueDepthScanner.isSupported {
                Text("This device has neither a LiDAR nor a TrueDepth camera. You can still view and share scans.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(.bar)
    }
}

extension ScanKind: Identifiable {
    var id: String { rawValue }
}

private struct ScanRow: View {
    let scan: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: scan.info.kind.symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.info.kind.title).font(.headline)
                Text(scan.info.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        var parts: [String] = []
        if scan.info.triangleCount > 0 { parts.append("\(scan.info.triangleCount.formatted()) triangles") }
        if scan.info.pointCount > 0 { parts.append("\(scan.info.pointCount.formatted()) points") }
        return parts.joined(separator: " · ")
    }
}
