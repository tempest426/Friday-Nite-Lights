import SwiftUI

@main
struct Friday_Nite_LightsApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Friday Nite Lights") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .applicationName: "Friday Nite Lights",
                            .applicationVersion: "1.0",
                            .credits: NSAttributedString(
                                string: """
                                Based on the 1980 Apple ][ classic
                                Tuesday Night Football
                                by Charles Anderson / Shoestring Software
                                
                                Modern remake by Lake Effect Software
                                """,
                                attributes: [
                                    .font: NSFont.systemFont(ofSize: 11),
                                    .foregroundColor: NSColor.secondaryLabelColor
                                ]
                            )
                        ]
                    )
                }
            }
        }
    }
}
