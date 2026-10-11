import SwiftUI

@main
struct FacetApp: App {
    @StateObject private var store = ScanStore()
    @StateObject private var share = WiFiShareServer()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(share)
        }
    }
}
