import SwiftUI

struct WiFiShareView: View {
    @EnvironmentObject private var share: WiFiShareServer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Share over Wi-Fi", isOn: Binding(
                        get: { share.isRunning },
                        set: { $0 ? share.start() : share.stop() }))
                } footer: {
                    Text("While this is on, any computer on the same Wi-Fi network can download your scans from a web browser. Nothing is uploaded anywhere.")
                }

                if share.isRunning, let address = share.address {
                    Section("Open this address on your computer") {
                        Text(address)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = address
                        } label: {
                            Label("Copy address", systemImage: "doc.on.doc")
                        }
                    }
                }

                if let error = share.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section("Other ways to get your scans") {
                    Label("Share button on any scan (AirDrop, Mail, Files…)", systemImage: "square.and.arrow.up")
                    Label("Files app › On My iPhone › Facet", systemImage: "folder")
                    Label("Finder or iTunes file sharing over USB", systemImage: "cable.connector")
                }
            }
            .navigationTitle("Wi-Fi sharing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
