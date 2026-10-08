import SwiftUI

struct MS100BTManagerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MS-100BT Manager") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Connect / Refresh") { model.readPedal() }.keyboardShortcut("r")
                Button("Back Up Pedal") { model.backupPedal() }.keyboardShortcut("b")
            }
        }
    }
}

MS100BTManagerApp.main()
