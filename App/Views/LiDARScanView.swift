import ARKit
import RealityKit
import ScanCore
import SwiftUI

struct LiDARScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var share: WiFiShareServer
    @StateObject private var scanner = LiDARScanner()
    @State private var showingSettings = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ARViewContainer(scanner: scanner).ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if let hint = scanner.trackingHint {
                    Text(hint)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                controls
            }
            .padding()

            if scanner.phase == .processing {
                ProgressView("Building model…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            scanner.stop()
            // Wi-Fi sharing keeps the screen awake on its own; don't undo that.
            UIApplication.shared.isIdleTimerDisabled = share.isRunning
        }
        .sheet(isPresented: $showingSettings) {
            LiDARSettingsView(settings: $scanner.settings, canChangeDensity: scanner.pointCount == 0)
                .presentationDetents([.medium])
        }
        .alert("Nothing to save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("\(scanner.pointCount.formatted()) points").font(.headline.monospacedDigit())
                Text("Range \(scanner.settings.maxDistance, specifier: "%.1f") m").font(.caption)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.headline).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button("Reset") { scanner.reset() }
                .buttonStyle(.bordered)
                .disabled(scanner.phase == .processing)

            Button {
                switch scanner.phase {
                case .scanning: scanner.pause()
                default: scanner.start()
                }
            } label: {
                Image(systemName: scanner.phase == .scanning ? "pause.fill" : "record.circle")
                    .font(.system(size: 34))
                    .frame(width: 76, height: 76)
                    .background(scanner.phase == .scanning ? Color.orange : Color.red, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(scanner.phase == .processing)

            Button("Done") { Task { await finish() } }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.pointCount == 0 || scanner.phase == .processing)
        }
        .padding(.bottom, 8)
    }

    private func finish() async {
        guard let result = await scanner.finish() else {
            errorMessage = "No depth was captured within range. Press record and move around your subject."
            return
        }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try ScanStore.write(kind: .lidar, mesh: result.mesh, points: result.points)
            }.value
            store.reload()
            dismiss()
        } catch {
            scanner.resumeAfterFailedFinish()
            errorMessage = "Couldn't save the scan: \(error.localizedDescription)"
        }
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let scanner: LiDARScanner

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        scanner.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

private struct LiDARSettingsView: View {
    @Binding var settings: LiDARScanner.Settings
    let canChangeDensity: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading) {
                        Text("Maximum distance: \(settings.maxDistance, specifier: "%.1f") m")
                        Slider(value: $settings.maxDistance, in: 0.3...5, step: 0.1)
                    }
                } footer: {
                    Text("Depth farther than this is ignored. Keep it short for objects so the background is cropped away.")
                }
                Section {
                    Picker("Detail", selection: $settings.voxelSize) {
                        Text("5 mm").tag(Float(0.005))
                        Text("1 cm").tag(Float(0.01))
                        Text("2 cm").tag(Float(0.02))
                    }
                    .disabled(!canChangeDensity)
                    Toggle("High-confidence depth only", isOn: $settings.highConfidenceOnly)
                } footer: {
                    Text(canChangeDensity ? "Size of the smallest detail in the mesh and the spacing of the points. 5 mm suits people and objects; use 2 cm for whole rooms."
                                          : "Reset the scan to change the detail.")
                }
            }
            .navigationTitle("Scan settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
