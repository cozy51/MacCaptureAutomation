import SwiftUI

@main
struct MacCaptureAutomationApp: App {
    @StateObject private var model = CaptureModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.light)
        }
    }
}
