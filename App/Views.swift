import SwiftUI
import Photos
import PhotosUI
import AVKit

private let canvas = Color(red: 0.96, green: 0.95, blue: 0.92)

struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if store.permitted {
                TabView {
                    NavigationStack { HomeView() }.tabItem { Label("整理", systemImage: "square.grid.2x2") }
                    NavigationStack { TripsView() }.tabItem { Label("出游", systemImage: "map") }
                    NavigationStack { PeopleView() }.tabItem { Label("人物", systemImage: "person.2") }
                    NavigationStack { PendingView() }.tabItem { Label("待删", systemImage: "trash") }
                        .badge(store.visiblePending.count)
                    NavigationStack { AIOrganizeView() }.tabItem { Label("AI", systemImage: "sparkles") }
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "leaf.circle.fill").font(.system(size: 72)).foregroundStyle(.tint)
                    Text("拾光").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("让照片各归其处").font(.title2)
                    Text("本地识别截图与人像，按行程回看记忆。原图留在系统相册，是否删除由你决定。")
                        .foregroundStyle(.secondary)
                    Button("选择可整理的照片") { Task { await store.connect() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    if store.authorization == .denied || store.authorization == .restricted {
                        Button("前往系统设置授权") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Text("可以先只授权少量测试照片。本地扫描不上传；可选 DeepSeek 功能需你主动发送。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
            }
        }
        .task { store.refresh() }
        .onChange(of: phase) { _, newValue in
            if newValue == .active && !store.scanning && !store.busy { store.refresh() }
            if newValue == .background { store.pause(); store.save() }
        }
        .alert("拾光", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("少一点杂乱\n多一点回忆").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("\(store.visibleActive.count) 项 · 本地扫描，AI 按需发送").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sparkles.rectangle.stack").font(.system(size: 40)).foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(store.status, systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.subheadline)
                    if store.scanning { ProgressView(value: store.progress) }
                    HStack {
                        Button(store.scanning ? "暂停扫描" : "本地扫描") {
                            if store.scanning { store.pause() } else { store.scan() }
                        }.buttonStyle(.borderedProminent).disabled(store.busy)
                        Button("刷新图库") { store.refresh() }.disabled(store.scanning || store.busy)
                    }
                    Text("只分析已下载素材。分类是建议，可在详情中纠正。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
                if store.authorization == .limited {
                    Button("当前为部分照片授权 · 更改可访问照片") { presentLimitedPicker() }
                        .font(.footnote)
                }
                if !query.isEmpty {
                    MediaGrid(records: store.visibleActive.filter { store.matches($0, query: query) })
                } else {
                    NavigationLink { CollectionView(title: "全部照片与视频", scope: .all) } label: {
                        Label("查看全部照片与视频", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered)
                    Text("已经分好，等你挑选").font(.title3.bold())
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PhotoTag.allCases) { tag in
                            NavigationLink { CollectionView(title: tag.rawValue, scope: .tag(tag)) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: tag.icon).font(.title2).foregroundStyle(.tint)
                                    HStack {
                                        Text(tag.rawValue).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(store.visibleActive.filter { $0.effectiveTags.contains(tag) }.count)").foregroundStyle(.secondary)
                                    }.font(.subheadline.weight(.medium))
                                }.padding(18).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        }
                    }
                    NavigationLink { SimilarView() } label: {
                        Label("相似照片审核 · \(store.similar.count) 组", systemImage: "square.on.square")
                    }
                    if !store.allKeywords.isEmpty {
                        Text("我的标签").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                            ForEach(store.allKeywords, id: \.self) { keyword in
                                NavigationLink { CollectionView(title: "#" + keyword, scope: .keyword(keyword)) } label: {
                                    Text("#" + keyword).font(.caption).padding(10)
                                        .frame(maxWidth: .infinity).background(.white, in: Capsule())
                                }
                            }
                        }
                    }
                    Text("人像检测不等于人物身份识别。人物名字由你关联；视频目前只分析封面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20)
        }.background(canvas).navigationTitle("拾光").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜文字、分类、人物或行程名")
    }
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
            Task { @MainActor in store.refresh() }
        }
    }
}

enum CollectionScope {
    case all, tag(PhotoTag), keyword(String), person(UUID), trip(UUID)
}

struct CollectionView: View {
    @EnvironmentObject var store: LibraryStore
    var title: String
    var scope: CollectionScope
    @State private var reviewing = false
    @State private var renaming = false
    @State private var newName = ""
    var records: [MediaRecord] {
        store.visibleActive.filter { record in
            switch scope {
            case .all: return true
            case .tag(let tag): return record.effectiveTags.contains(tag)
            case .keyword(let keyword): return record.customTags.contains(where: { $0.localizedCaseInsensitiveCompare(keyword) == .orderedSame })
            case .person(let id): return record.people.contains(id)
            case .trip(let id): return store.state.trips.first(where: { $0.id == id })?.members.contains(record.id) == true
            }
        }
    }
    var displayTitle: String {
        if case .trip(let id) = scope { return store.state.trips.first(where: { $0.id == id })?.name ?? title }
        return title
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(records.count) 项").foregroundStyle(.secondary)
                    Spacer()
                    Button("连续整理") { reviewing = true }.buttonStyle(.borderedProminent).disabled(records.isEmpty)
                }
                MediaGrid(records: records)
            }.padding()
        }.background(canvas).navigationTitle(displayTitle).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("创建为系统相册") {
                    let ids = records.map(\.id)
                    Task { await store.exportAlbum(name: displayTitle, ids: ids) }
                }.disabled(store.busy || store.scanning || records.isEmpty)
                if !store.state.people.isEmpty {
                    Menu("将整组关联人物") {
                        ForEach(store.state.people) { person in
                            Button(person.name) { store.associatePerson(person.id, ids: records.map(\.id)) }
                        }
                    }
                }
                if case .trip = scope {
                    Button("修改行程名称") { newName = displayTitle; renaming = true }
                }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .sheet(isPresented: $reviewing) { NavigationStack { ReviewView(ids: records.map(\.id)) } }
        .alert("行程名称", isPresented: $renaming) {
            TextField("例如：中秋 · 长沙", text: $newName)
            Button("保存") { if case .trip(let id) = scope { store.renameTrip(id, name: newName) } }
            Button("取消", role: .cancel) {}
        }
    }
}

struct MediaGrid: View {
    @EnvironmentObject var store: LibraryStore
    var records: [MediaRecord]
    var body: some View {
        if records.isEmpty {
            ContentUnavailableView("这里还没有照片", systemImage: "photo", description: Text("先运行本地扫描，或手动关联分类。"))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                ForEach(records) { record in
                    NavigationLink { DetailView(id: record.id) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                        Thumbnail(id: record.id)
                            .frame(height: 125).frame(maxWidth: .infinity).clipped()
                            .overlay(alignment: .bottomTrailing) {
                                if record.isVideo {
                                    Label("\(Int(record.duration))秒", systemImage: "play.fill")
                                        .font(.caption2).padding(5).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(4)
                                }
                            }.clipShape(RoundedRectangle(cornerRadius: 10))
                            let labels = store.tagLabels(for: record)
                            Text(labels.prefix(2).map { "#" + $0 }.joined(separator: " "))
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            if labels.count > 2 {
                                Text("另有 \(labels.count - 2) 个标签").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct Thumbnail: View {
    var id: String
    var fit = false
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.gray.opacity(0.12)
            if let image {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            }
        }
        .task(id: id) {
            image = nil
            let result = await PhotoAccess.image(id: id, size: CGSize(width: fit ? 1400 : 350, height: fit ? 1400 : 350))
            if !Task.isCancelled { image = result }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: LibraryStore
    var id: String
    @State private var player: AVPlayer?
    @State private var loadingVideo = false
    @State private var showingAI = false
    @State private var keywordInput = ""
    var record: MediaRecord? { store.state.records[id] }
    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 20) {
                    if let player { VideoPlayer(player: player).frame(height: 340) }
                    else { Thumbnail(id: id, fit: true).frame(height: 340).clipped() }
                    if record.isVideo {
                        Button(loadingVideo ? "正在读取本地视频…" : "播放本地视频") { loadVideo() }.disabled(loadingVideo)
                        Text("当前只识别封面，不包含语音转录或祝福对象识别。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    if let summary = record.aiSummary { Label(summary, systemImage: "sparkles").font(.headline) }
                    Button("用 DeepSeek 深入识别") { showingAI = true }.buttonStyle(.bordered)
                    if record.unavailable {
                        Label("素材可能仅在 iCloud；请先在系统照片中下载后再扫描。", systemImage: "icloud.slash")
                            .font(.footnote)
                    }
                    Text("照片标签").font(.headline)
                    Text(store.tagLabels(for: record).map { "#" + $0 }.joined(separator: "  "))
                        .font(.subheadline).foregroundStyle(.tint).textSelection(.enabled)
                    HStack {
                        TextField("添加标签，例如：夜景、聚餐", text: $keywordInput)
                            .textFieldStyle(.roundedBorder).submitLabel(.done)
                            .onSubmit { store.addKeywords(id, input: keywordInput); keywordInput = "" }
                        Button("添加") { store.addKeywords(id, input: keywordInput); keywordInput = "" }
                            .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("自由标签最多 40 个，每个 24 字。可用逗号分隔；点击下方标签的 × 移除，不会删除照片。")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                        ForEach(record.customTags, id: \.self) { keyword in
                            Button { store.removeKeyword(id, keyword: keyword) } label: {
                                Text("#\(keyword) ×").font(.caption).padding(8)
                                    .frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.1), in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("移除标签 " + keyword)
                        }
                    }
                    Text("分类标签").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) {
                        ForEach(PhotoTag.allCases) { tag in
                            Button {
                                store.setTag(id, tag, enabled: !record.effectiveTags.contains(tag))
                            } label: {
                                Text(tag.rawValue).font(.caption).padding(10).frame(maxWidth: .infinity)
                                    .background(record.effectiveTags.contains(tag) ? Color.accentColor.opacity(0.18) : .gray.opacity(0.1), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("关联人物").font(.headline)
                    if store.state.people.isEmpty { Text("先在「人物」页创建桐桐等名字。这里是手动关联。 ").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(store.state.people) { person in
                        Button { store.togglePerson(id, person.id) } label: {
                            Label(person.name, systemImage: record.people.contains(person.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Text("关联行程").font(.headline)
                    ForEach(store.state.trips) { trip in
                        Button { store.toggleTrip(id, trip: trip.id) } label: {
                            Label(trip.name, systemImage: trip.members.contains(id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    DisclosureGroup("查看识别依据与文字") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(record.reasons, id: \.self) { Text("• " + $0) }
                            Text(record.text.isEmpty ? "没有识别到文字" : record.text).textSelection(.enabled)
                        }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(role: store.state.pending.contains(id) ? nil : .destructive) {
                        if store.state.pending.contains(id) { store.restore(id) } else { store.stage(id) }
                    } label: {
                        Label(store.state.pending.contains(id) ? "从待删区恢复" : "移入待删区", systemImage: "trash")
                    }.buttonStyle(.bordered)
                }.padding()
            } else { ContentUnavailableView("照片已移除", systemImage: "photo") }
        }.background(canvas).navigationTitle("照片详情").navigationBarTitleDisplayMode(.inline)
            .onDisappear { player?.pause() }
            .sheet(isPresented: $showingAI) { AIPhotoView(id: id) }
    }
    private func loadVideo() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
        loadingVideo = true
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
            Task { @MainActor in
                loadingVideo = false
                if let item { player = AVPlayer(playerItem: item) }
                else { store.message = "无法读取本地视频。若原件在 iCloud，请先在系统照片中下载。" }
            }
        }
    }
}

struct ReviewView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var index = 0
    @State private var offset: CGSize = .zero
    private var current: String? { index < ids.count ? ids[index] : nil }
    var body: some View {
        VStack(spacing: 18) {
            Text("\(min(index + 1, ids.count)) / \(ids.count)").font(.subheadline).foregroundStyle(.secondary)
            if let current {
                Thumbnail(id: current, fit: true).frame(maxHeight: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .offset(offset).rotationEffect(.degrees(Double(offset.width / 30)))
                    .overlay(alignment: .top) {
                        if offset.height < -45 { Label("放入待删", systemImage: "trash").padding().background(.regularMaterial, in: Capsule()).foregroundStyle(.red) }
                    }
                    .gesture(DragGesture().onChanged { offset = $0.translation }.onEnded { value in
                        if value.translation.height < -100 { stageCurrent() }
                        else if abs(value.translation.width) > 100 { index += 1 }
                        withAnimation { offset = .zero }
                    })
                Text("上滑待删 · 左右滑跳过 · 原图暂不删除").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("跳过") { index += 1 }.buttonStyle(.bordered)
                    Button("放入待删", role: .destructive) { stageCurrent() }.buttonStyle(.bordered)
                }
                NavigationLink("查看详情与分类") { DetailView(id: current) }
            } else {
                ContentUnavailableView("这一组看完了", systemImage: "checkmark.circle", description: Text("待删照片可以在「待删」页集中审核。"))
            }
            Button("撤销最近一次待删") {
                let previous = store.state.lastStaged
                store.undo()
                if let previous, let position = ids.firstIndex(of: previous) { index = position }
            }.disabled(store.state.lastStaged == nil)
        }.padding().background(canvas).navigationTitle("连续整理").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onAppear { skipPending() }
            .onChange(of: index) { _, _ in skipPending() }
    }
    private func stageCurrent() {
        guard let current else { return }
        store.stage(current); index += 1
    }
    private func skipPending() {
        while index < ids.count && (store.state.pending.contains(ids[index]) || store.state.records[ids[index]] == nil) { index += 1 }
    }
}

struct PendingView: View {
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("先放这里，想好再删").font(.title2.bold())
                Text("这里是 App 内的待删队列，原图还在系统相册。点击图片可以恢复。")
                    .font(.subheadline).foregroundStyle(.secondary)
                MediaGrid(records: store.visiblePending)
                if !store.visiblePending.isEmpty {
                    Button("全部恢复") {
                        for record in store.visiblePending { store.restore(record.id) }
                    }.buttonStyle(.bordered)
                    Button(role: .destructive) { Task { await store.deletePending() } } label: {
                        Text(store.busy ? "等待系统处理…" : "请求系统删除 \(store.visiblePending.count) 项")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(store.busy || store.scanning)
                    Text("下一步由 iOS 确认。开启 iCloud 照片时，删除会同步到其他设备。删除后请到系统「最近删除」中恢复或清空。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.padding()
        }.background(canvas).navigationTitle("待删")
    }
}

struct PeopleView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var naming = false
    @State private var name = ""
    var body: some View {
        List {
            Section {
                NavigationLink { CollectionView(title: "全部人像", scope: .tag(.portrait)) } label: {
                    Label("检测到人脸的照片", systemImage: "person.crop.rectangle")
                }
            } footer: { Text("第一版检测人脸，但不自动认出同一个人。创建名字后，在照片详情中关联，不会把相似面孔当作确定身份。") }
            Section("我认识的人") {
                ForEach(store.state.people) { person in
                    NavigationLink { CollectionView(title: person.name, scope: .person(person.id)) } label: {
                        Label(person.name, systemImage: "person.crop.circle")
                    }
                }
                Button("添加人物") { name = ""; naming = true }
            }
        }.navigationTitle("人物")
        .alert("人物名字", isPresented: $naming) {
            TextField("例如：桐桐", text: $name)
            Button("添加") { store.addPerson(name) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct TripsView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var creating = false
    var body: some View {
        List {
            Section {
                Text("按时间与已有定位生成候选。你可以改成「中秋 · 长沙」，也可以按日期创建，再补充朋友发来的照片。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.state.trips) { trip in
                NavigationLink { CollectionView(title: trip.name, scope: .trip(trip.id)) } label: {
                    HStack {
                        Image(systemName: "map.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(trip.name)
                            Text("\(trip.members.intersection(Set(store.visibleActive.map(\.id))).count) 项 · \(trip.manual ? "已手动整理" : "待确认候选")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle("每一次出发")
            .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $creating) { CreateTripView() }
    }
}

struct CreateTripView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Date()
    var body: some View {
        NavigationStack {
            Form {
                TextField("行程名，例如：中秋 · 长沙", text: $name)
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                DatePicker("结束日期", selection: $end, in: start..., displayedComponents: .date)
                Text("把此日期范围内的可访问照片和视频加入行程。之后可在照片详情中增减，不移动或复制原图。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("创建行程")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { store.createTrip(name: name, start: start, end: max(start, end)); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SimilarView: View {
    @EnvironmentObject var store: LibraryStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("只是相似，不一定重复。请查看原图后决定；系统不会自动挑选或删除。最多显示 500 对。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.similar.isEmpty { ContentUnavailableView("暂无候选", systemImage: "square.on.square", description: Text("完成本地扫描后在这里查看。")) }
                ForEach(Array(store.similar.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(pair, id: \.self) { id in
                            if store.visibleIDs.contains(id), store.state.records[id] != nil {
                                VStack {
                                    NavigationLink { DetailView(id: id) } label: {
                                        Thumbnail(id: id, fit: true).frame(height: 160).clipped()
                                    }
                                    Button(store.state.pending.contains(id) ? "恢复" : "待删", role: .destructive) {
                                        if store.state.pending.contains(id) { store.restore(id) } else { store.stage(id) }
                                    }.buttonStyle(.bordered)
                                }.frame(maxWidth: .infinity)
                            }
                        }
                    }.padding().background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding()
        }.background(canvas).navigationTitle("相似照片")
    }
}

