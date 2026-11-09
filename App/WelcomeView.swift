import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @AppStorage("onboardingComplete") private var finished = false
    @AppStorage("screenshotsOnly") private var screenshots = true
    @AppStorage("backgroundEnabled") private var background = true
    @State private var step = 0
    @State private var requesting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer()
            Image(systemName: ["photo.stack", "photo.badge.checkmark", "slider.horizontal.3", "checkmark.circle"][step])
                .font(.system(size: 56,weight: .ultraLight)).foregroundStyle(Palette.accent)
            Text(LocalizedStringKey(["想先整理什么？", "让拾光看看照片", "按你的习惯整理", "准备好了"][step]))
                .font(.largeTitle.weight(.medium))
            switch step {
            case 0:
                Button { screenshots = true; step = 1 } label: { Label("截图太多",systemImage:"viewfinder").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.bordered)
                Button { screenshots = false; step = 1 } label: { Label("旅行、美食和日常照片",systemImage:"photo.on.rectangle").frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.bordered)
            case 1:
                Text("先读取照片目录，不会立即识别整库，也不会上传照片。阅读下一步时，目录会在后台读取。")
                    .foregroundStyle(Palette.secondary)
                Button(requesting ? "正在请求…" : "允许照片访问") {
                    requesting = true
                    Task { await store.connect(); requesting = false; if store.permitted { step = 2 } }
                }.buttonStyle(QuietPrimaryButtonStyle()).disabled(requesting)
                if store.authorization == .denied {
                    Button("打开系统设置") { if let url=URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            case 2:
                Toggle("优先整理截图",isOn:$screenshots)
                Toggle("后台继续整理",isOn:$background)
                Text("搜索索引和截图文字可以分别处理。真正删除前，你会集中确认。")
                    .foregroundStyle(Palette.secondary)
                Button("下一步") { step = 3 }.buttonStyle(QuietPrimaryButtonStyle())
            default:
                if store.refreshing { ProgressView("正在读取照片目录…") }
                else { Text(L.f("已读取 %d 项",store.visibleIDs.count)) }
                Text("目录读取完成后，就能浏览相册。需要按画面找照片时，再建立本地搜索索引。")
                    .foregroundStyle(Palette.secondary)
                Button("进入相册") { finished = true; dismiss() }.buttonStyle(QuietPrimaryButtonStyle())
            }
            Spacer()
            HStack {
                if step > 0 { Button("上一步") { step -= 1 } }
                Spacer()
                Text("\(step+1) / 4").font(.caption).foregroundStyle(Palette.secondary)
            }
        }.padding(32).background(AlbumCanvas())
    }
}
