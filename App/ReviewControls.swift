import SwiftUI

// One fixed control row for every collection and both media types.
struct ReviewControls: View {
    let pending: Bool
    let clear: () -> Void
    let next: () -> Void
    let stageOrRestore: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action:clear) {
                Label("查看清晰",systemImage:"arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth:.infinity,minHeight:36)
            }.accessibilityIdentifier("review.clear")
            Button(action:next) { Text("下一张").frame(maxWidth:.infinity,minHeight:36) }
                .accessibilityIdentifier("review.next")
            Button(role:pending ? nil : .destructive,action:stageOrRestore) {
                Text(L.t(pending ? "恢复" : "放入待删")).frame(maxWidth:.infinity,minHeight:36)
            }.accessibilityIdentifier("review.stage")
        }.font(.subheadline).buttonStyle(.bordered).controlSize(.regular)
            .lineLimit(2).minimumScaleFactor(0.8)
    }
}
