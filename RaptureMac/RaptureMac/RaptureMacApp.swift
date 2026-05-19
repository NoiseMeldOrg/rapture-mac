import SwiftUI

@main
struct RaptureMacApp: App {
    @State private var appState: AppState
    @State private var pipeline: Pipeline

    init() {
        let state = AppState()
        _appState = State(wrappedValue: state)
        _pipeline = State(wrappedValue: Pipeline(appState: state))
    }

    var body: some Scene {
        Window("Rapture for Mac", id: "permissions") {
            PermissionsView()
                .environment(appState)
                .frame(minWidth: 480, minHeight: 320)
                .task {
                    await pipeline.start()
                }
        }
        .windowResizability(.contentSize)
    }
}
