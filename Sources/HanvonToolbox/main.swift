import SwiftUI

HanvonToolboxApp.main()

@MainActor
struct HanvonToolboxApp: App {
    var body: some Scene {
        Window("汉王电纸书工具箱", id: "toolbox") {
            ToolboxView()
                .frame(minWidth: 840, minHeight: 510)
        }
        .defaultSize(width: 1240, height: 690)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
