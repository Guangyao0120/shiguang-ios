import SwiftUI

@main
struct ShiguangApp: App {
    @StateObject private var store = LibraryStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(Palette.accent).foregroundStyle(Palette.ink)
        }
    }
}
