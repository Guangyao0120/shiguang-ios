import SwiftUI

@main
struct ShiguangApp: App {
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Color(red: 0.12, green: 0.45, blue: 0.37))
        }
    }
}
