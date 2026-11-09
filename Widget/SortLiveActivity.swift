import ActivityKit
import WidgetKit
import SwiftUI

@main
struct SortLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SortActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName:"leaf.fill").font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading,spacing: 8) {
                    Text(context.state.title).font(.headline)
                    ProgressView(value: Double(context.state.completed),total: Double(max(1,context.state.total)))
                    Text("\(context.state.completed)/\(context.state.total)").font(.caption).monospacedDigit()
                }
                Link(context.state.stopLabel,destination:URL(string:"shiguang://scan/stop")!).font(.subheadline)
            }.padding().activityBackgroundTint(Color(.secondarySystemBackground))
                .widgetURL(URL(string:"shiguang://scan"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName:"leaf.fill").foregroundStyle(.green) }
                DynamicIslandExpandedRegion(.trailing) { Text("\(context.state.completed)/\(context.state.total)").font(.caption).monospacedDigit() }
                DynamicIslandExpandedRegion(.center) { Text(context.state.title).font(.subheadline).lineLimit(2) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ProgressView(value:Double(context.state.completed),total:Double(max(1,context.state.total)))
                        Link(context.state.stopLabel,destination:URL(string:"shiguang://scan/stop")!).font(.subheadline)
                    }.padding(.vertical,6)
                }
            } compactLeading: {
                Image(systemName:"leaf.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text(context.state.total > 0 ? "\(context.state.completed * 100 / context.state.total)%" : "…").font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName:"leaf.fill").foregroundStyle(.green)
            }.widgetURL(URL(string:"shiguang://scan"))
        }
    }
}
