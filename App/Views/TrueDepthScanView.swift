import AVFoundation
import ScanCore
import SwiftUI

struct TrueDepthScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ScanStore
    @EnvironmentObject private var share: WiFiShareServer
    @StateObject private var scanner = TrueDepthScanner()
    @State private var preview: Mesh?
    @State private var errorMessage: String?
    @State private var saving = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let preview {
                ModelView(mesh: preview, unlit: true)
                    .ignoresSafeArea()
            } else {
                CameraPreview(session: scanner.session).ignoresSafeArea()
                guideOverlay
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                statusText
                if preview == nil { captureControls } else { reviewControls }
            }
            .padding()
        }
        .onAppear {
            scanner.startSession()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            scanner.stopSession()
            // Wi-Fi sharing keeps the screen awake on its own; don't undo that.
            UIApplication.shared.isIdleTimerDisabled = share.isRunning
        }
        .alert("Scan failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var guideOverlay: some View {
        // A face-sized oval to help framing.
        Ellipse()
            .strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .frame(width: 240, height: 320)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusText: some View {
        let text: String? = {
            switch scanner.phase {
            case .starting: return "Starting camera…"
            case .ready: return preview == nil ? "Hold still, then tap capture" : nil
            case .capturing(let progress): return "Hold still… \(Int(progress * 100))%"
            case .processing: return "Building mesh…"
            case .failed(let message): return message
            }
        }()
        if let text {
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var captureControls: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Background cut-off: \(scanner.settings.maxDistance, specifier: "%.2f") m").font(.caption)
                Slider(value: $scanner.settings.maxDistance, in: 0.25...1.2, step: 0.05)
                Picker("Detail", selection: $scanner.settings.step) {
                    Text("Fine").tag(1)
                    Text("Normal").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            Button {
                Task {
                    if let mesh = await scanner.capture() {
                        preview = mesh
                    } else {
                        errorMessage = "Nothing was captured within range. Move closer or raise the cut-off distance."
                    }
                }
            } label: {
                Circle().fill(.white).frame(width: 72, height: 72)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 6).padding(-8))
            }
            .disabled(scanner.phase != .ready)
        }
    }

    private var reviewControls: some View {
        HStack(spacing: 16) {
            Button("Retake") { preview = nil }
                .buttonStyle(.bordered)
            Button {
                guard let mesh = preview else { return }
                saving = true
                Task {
                    do {
                        _ = try await Task.detached(priority: .userInitiated) {
                            try ScanStore.write(kind: .trueDepth, mesh: mesh, points: nil)
                        }.value
                        store.reload()
                        dismiss()
                    } catch {
                        errorMessage = "Couldn't save the scan: \(error.localizedDescription)"
                    }
                    saving = false
                }
            } label: {
                if saving { ProgressView() } else { Text("Save") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving)
        }
        .controlSize(.large)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
