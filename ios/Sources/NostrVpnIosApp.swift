import SwiftUI

@main
struct NostrVpnIosApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    model.start()
                }
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}
