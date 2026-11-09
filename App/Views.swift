import SwiftUI
import Photos
import PhotosUI
import AVKit

private let canvas = Palette.canvas

struct RootView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.scenePhase) private var phase
    @State private var selectedTab = DesignPreview.tab
    var body: some View {
        Group {
            if store.permitted {
                if !store.loaded {
                    VStack(spacing: 18) {
                        ProgressView()
                        Text("正在读取上次的整理结果").font(.headline)
                        
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
                } else {
                if #available(iOS 26.0, *) {
                    navigationTabs
                } else {
                    navigationTabs.toolbar(.hidden, for: .tabBar)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if store.detailLayers == 0 { GlassTabBar(selection: $selectedTab, pendingCount: store.visiblePending.count) }
                        }
                }
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "leaf.circle.fill").font(.system(size: 72)).foregroundStyle(.tint)
                    Text("拾光").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("让照片各归其处").font(.title2)
                    Text("整理照片，收藏回忆。")
                        .foregroundStyle(Palette.secondary)
                    Button("选择可整理的照片") { Task { await store.connect() } }
                        .buttonStyle(QuietPrimaryButtonStyle()).controlSize(.large)
                    if store.authorization == .denied || store.authorization == .restricted {
                        Button("前往系统设置授权") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    Text("照片留在本机，删除由你确认。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(canvas)
            }
        }
        .task { await store.start() }

        .onChange(of: phase) { _, newValue in
            if newValue == .active { store.refreshIfNeeded() }
            if newValue == .background { ScanRuntime.shared.enterBackground(); store.save(immediately: true); PhotoAccess.clearCache() }
        }
        .alert("拾光", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
    private var navigationTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }.tabItem { Label("整理", systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { TripsView() }.tabItem { Label("出游", systemImage: "map") }.tag(1)
            NavigationStack { PeopleView() }.tabItem { Label("人物", systemImage: "person.2") }.tag(2)
            NavigationStack { PendingView() }.tabItem { Label("待删", systemImage: "trash") }.badge(store.visiblePending.count).tag(3)
            NavigationStack { AIOrganizeView() }.tabItem { Label("AI", systemImage: "sparkles") }.tag(4)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: LibraryStore
    @State private var query = ""
    @State private var searchResults: [MediaRecord] = []
    @State private var showingHelp = false
    @State private var creatingTag = false
    @State private var tagName = ""
    @AppStorage("screenshotsOnly") private var screenshotsOnly = true
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("留住喜欢的").font(.system(size: 30, weight: .medium, design: .serif))
                        Text("\(store.visibleActive.count.formatted()) 项收藏").font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Image(systemName: "leaf").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label(store.status, systemImage: store.scanning ? "viewfinder" : "checkmark.circle")
                        .font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
                    if store.scanning { ProgressView(value: store.progress) }
                    HStack {
                        Button(store.scanning ? "暂停" : (screenshotsOnly ? "整理截图" : "开始整理")) {
                            if store.scanning { ScanRuntime.shared.pause() } else { ScanRuntime.shared.start() }
                        }.buttonStyle(QuietPrimaryButtonStyle()).disabled(store.busy || store.refreshing || !store.loaded)
                        Menu("更多") {
                            Button("刷新相册") { store.refresh() }
                            Button("整理所有图片") { ScanRuntime.shared.start(screenshotsOnly: false) }
                            Button("使用说明", systemImage: "info.circle") { showingHelp = true }
                        }.disabled(store.scanning || store.busy || store.refreshing || !store.loaded)
                    }
                    if store.refreshing { ProgressView() }
                }.padding().frame(maxWidth: .infinity, alignment: .leading).paperCard()
                if store.authorization == .limited {
                    Button("管理可访问的照片") { presentLimitedPicker() }
                        .font(.footnote)
                }
                if !query.isEmpty {
                    MediaGrid(records: searchResults)
                } else {
                    NavigationLink { CollectionView(title: "全部照片与视频", scope: .all) } label: {
                        Label("查看全部照片与视频", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.bordered)
                    Text("分类").font(.title3.weight(.medium))
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PhotoTag.allCases) { tag in
                            NavigationLink { CollectionView(title: tag.rawValue, scope: .tag(tag)) } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: tag.icon).font(.title2).foregroundStyle(.tint)
                                    HStack {
                                        Text(tag.rawValue).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(store.index.byTag[tag]?.count ?? 0)").foregroundStyle(Palette.secondary)
                                    }.font(.subheadline.weight(.medium))
                                }.padding(20).paperCard(radius: 22)
                            }.buttonStyle(.plain)
                        }
                    }
                    NavigationLink { SimilarView() } label: {
                        Label("相似照片 · \(store.similar.count) 组", systemImage: "square.on.square")
                    }
                    Group {
                        HStack {
                            Text("自定义分类").font(.title3.weight(.medium))
                            Spacer()
                            Button { tagName = ""; creatingTag = true } label: { Image(systemName: "plus") }
                                .accessibilityLabel("新建自定义分类")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                            ForEach(store.allKeywords, id: \.self) { keyword in
                                NavigationLink { CollectionView(title: "#" + keyword, scope: .keyword(keyword)) } label: {
                                    Text("#" + keyword).font(.caption).padding(10)
                                        .frame(maxWidth: .infinity).background(Palette.surface, in: Capsule())
                                }
                            }
                        }
                    }
                    
                }
            }.padding(20)
        }.background(canvas).navigationTitle("拾光").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索照片与标签")
            .sheet(isPresented: $showingHelp) { AlbumHelpView() }
            .toolbar { NavigationLink { AlbumSettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
            .alert("自定义分类", isPresented: $creatingTag) {
                TextField("例如：工作、待买、纪念", text: $tagName)
                Button("创建") { store.createCustomTag(tagName) }
                Button("取消", role: .cancel) { }
            }
            .task(id: "\(store.indexVersion):\(query)") {
                guard !query.isEmpty else { searchResults = []; return }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                let snapshot = store.index, words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                let result = await Task.detached(priority: .utility) {
                    snapshot.active.filter { record in words.allSatisfy { snapshot.search[record.id]?.contains($0) == true } }
                }.value
                if !Task.isCancelled { searchResults = result }
            }
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
        switch scope {
        case .all: return store.index.active
        case .tag(let tag): return store.index.byTag[tag] ?? []
        case .keyword(let keyword): return store.index.byKeyword[keyword.lowercased()] ?? []
        case .person(let id): return store.index.byPerson[id] ?? []
        case .trip(let id): return store.index.byTrip[id] ?? []
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
                    Text("\(records.count) 项").foregroundStyle(Palette.secondary)
                    Spacer()
                    Button("连续整理") { reviewing = true }.buttonStyle(QuietPrimaryButtonStyle()).disabled(records.isEmpty)
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
    @State private var displayLimit = 120
    var body: some View {
        if records.isEmpty {
            ContentUnavailableView("暂无照片", systemImage: "photo")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 4)], spacing: 4) {
                ForEach(Array(records.prefix(displayLimit))) { record in
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
                            if let title = record.videoTitle, record.isVideo {
                                Text(title).font(.caption.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                            }
                            Text(labels.prefix(2).map { "#" + $0 }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(Palette.secondary).lineLimit(1)

                        }
                    }.buttonStyle(.plain)
                }
            }
            if records.count > displayLimit {
                Button("再显示120项（共\(records.count)项）") { displayLimit += 120 }
                    .buttonStyle(.bordered).padding(.vertical)
            }
        }
    }
}

struct Thumbnail: View {
    var id: String
    var fit = false
    var resolution: CGFloat = 320
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Palette.surface
            if let image {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else {
                Image(systemName: DesignPreview.enabled ? "photo" : "photo.badge.exclamationmark")
                    .font(.title2.weight(.ultraLight)).foregroundStyle(Palette.secondary)
            }
        }
        .task(id: id) {
            image = nil
            guard !DesignPreview.enabled else { return }
            let result = await PhotoAccess.image(id: id, size: CGSize(width: resolution, height: resolution))
            if !Task.isCancelled { image = result }
        }
        .onDisappear { image = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in image = nil }
    }
}

struct DetailView: View {
    @EnvironmentObject var store: LibraryStore
    var id: String
    @State private var player: AVPlayer?
    @State private var loadingVideo = false
    @State private var showingAI = false
    @State private var showingVideoTools = false
    @State private var showingOriginal = false
    @State private var keywordInput = ""
    var record: MediaRecord? { store.state.records[id] }
    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(record.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Button(role: store.state.pending.contains(id) ? nil : .destructive) {
                            if store.state.pending.contains(id) { store.restore(id) } else { store.stage(id) }
                        } label: {
                            Label(store.state.pending.contains(id) ? "恢复" : "移入待删", systemImage: store.state.pending.contains(id) ? "arrow.uturn.backward" : "trash")
                        }.buttonStyle(.bordered)
                    }
                    if let player { VideoPlayer(player: player).frame(height: 340) }
                    else {
                        Button { if record.isVideo { loadVideo() } else { showingOriginal = true } } label: {
                            Thumbnail(id: id, fit: true, resolution: 1000).frame(height: 340).clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    Label(record.isVideo ? "播放" : "查看清晰原图", systemImage: record.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                                        .font(.caption.weight(.medium)).padding(10).background(.regularMaterial, in: Capsule()).padding(10)
                                }
                        }.buttonStyle(.plain)
                    }
                    if record.isVideo {
                        Button(loadingVideo ? "正在读取本地视频…" : "播放本地视频") { loadVideo() }.disabled(loadingVideo)
                        if let title = record.videoTitle { Text(title).font(.title3.weight(.medium)) }
                        Button("视频标题与转写", systemImage: "waveform") { showingVideoTools = true }
                            .buttonStyle(.bordered)
                        
                    }
                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Palette.secondary)
                    if let summary = record.aiSummary { Label(summary, systemImage: "sparkles").font(.headline) }
                    Button("用 DeepSeek 深入识别") { showingAI = true }.buttonStyle(.bordered)
                    if record.unavailable {
                        Label("请先在苹果照片中下载原件", systemImage: "icloud.slash")
                            .font(.footnote)
                    }
                    Text("自定义标签").font(.headline)
                    Text(store.tagLabels(for: record).map { "#" + $0 }.joined(separator: "  "))
                        .font(.subheadline).foregroundStyle(.tint).textSelection(.enabled)
                    HStack {
                        TextField("添加标签，例如：夜景、聚餐", text: $keywordInput)
                            .textFieldStyle(.roundedBorder).submitLabel(.done)
                            .onSubmit { store.createCustomTag(keywordInput); store.addKeywords(id, input: keywordInput); keywordInput = "" }
                        Button("添加") { store.createCustomTag(keywordInput); store.addKeywords(id, input: keywordInput); keywordInput = "" }
                            .disabled(keywordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                        ForEach(record.customTags, id: \.self) { keyword in
                            Button { store.removeKeyword(id, keyword: keyword) } label: {
                                Text("#\(keyword) ×").font(.caption).padding(8)
                                    .frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.1), in: Capsule())
                            }.buttonStyle(.plain).accessibilityLabel("移除标签 " + keyword)
                        }
                    }
                    if !store.allKeywords.isEmpty {
                        DisclosureGroup("已有自定义分类") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) {
                                ForEach(store.allKeywords, id: \.self) { name in
                                    Button {
                                        if record.customTags.contains(name) { store.removeKeyword(id, keyword: name) }
                                        else { store.addKeywords(id, input: name) }
                                    } label: {
                                        Label(name, systemImage: record.customTags.contains(name) ? "checkmark.circle.fill" : "circle")
                                            .font(.caption).padding(8)
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    Text("系统分类").font(.headline)
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
                    if store.state.people.isEmpty { Text("在「人物」中添加名字").font(.footnote).foregroundStyle(Palette.secondary) }
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

                }.padding()
            } else { ContentUnavailableView("照片已移除", systemImage: "photo") }
        }.background(canvas).navigationTitle("照片详情").navigationBarTitleDisplayMode(.inline)
            .safeAreaPadding(.bottom, 24)
            .toolbar(.hidden, for: .tabBar)
            .onAppear { store.detailLayers += 1 }
            .onDisappear { player?.pause(); store.detailLayers = max(0, store.detailLayers - 1) }
            .sheet(isPresented: $showingAI) { AIPhotoView(id: id) }
            .sheet(isPresented: $showingVideoTools) { VideoOrganizeView(id: id) }
            .fullScreenCover(isPresented: $showingOriginal) { OriginalPhotoView(id: id) }
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
            Text("\(min(index + 1, ids.count)) / \(ids.count)").font(.subheadline).foregroundStyle(Palette.secondary)
            if let current {
                Thumbnail(id: current, fit: true, resolution: 1000).frame(maxHeight: .infinity).clipped()
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
                Text("上滑待删 · 左右跳过").font(.footnote).foregroundStyle(Palette.secondary)
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
                Text("再想一想，也没关系").font(.title2.bold())
                Text("原图仍在相册，可随时恢复。")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                MediaGrid(records: store.visiblePending)
                if !store.visiblePending.isEmpty {
                    Button("全部恢复") {
                        store.restoreAllPending()
                    }.buttonStyle(.bordered)
                    Button(role: .destructive) { Task { await store.deletePending() } } label: {
                        Text(store.busy ? "等待系统处理…" : "请求系统删除 \(store.visiblePending.count) 项")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(QuietPrimaryButtonStyle()).disabled(store.busy || store.scanning)
                    Text("删除需系统确认，并同步 iCloud；可从「最近删除」恢复。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
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
                    Label("全部人像", systemImage: "person.crop.rectangle")
                }
            }
            Section("我的人物") {
                ForEach(store.state.people) { person in
                    NavigationLink { CollectionView(title: person.name, scope: .person(person.id)) } label: {
                        Label(person.name, systemImage: "person.crop.circle")
                    }
                }
                Button("添加人物") { name = ""; naming = true }
            }
        }.paperList().navigationTitle("人物")
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
            if store.state.trips.isEmpty {
                ContentUnavailableView("每一次出发，都值得收藏", systemImage: "map", description: Text("按日期创建，或整理行程候选"))
                    .listRowBackground(Color.clear)
            }
            ForEach(store.state.trips) { trip in
                NavigationLink { CollectionView(title: trip.name, scope: .trip(trip.id)) } label: {
                    HStack {
                        Image(systemName: "map.fill").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(trip.name)
                            Text("\(store.index.byTrip[trip.id]?.count ?? 0) 项 · \(trip.manual ? "已手动整理" : "待确认候选")")
                                .font(.caption).foregroundStyle(Palette.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.paperList().navigationTitle("出游")
            .toolbar {
                Button("整理候选") { store.rebuildTrips() }.disabled(store.busy || store.scanning || store.refreshing)
                Button { creating = true } label: { Image(systemName: "plus") }
            }
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
                Text("按所选日期归入，不复制原图。")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }.paperList().navigationTitle("创建行程")
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
            LazyVStack(alignment: .leading, spacing: 20) {
                Button(store.busy ? "正在比对…" : "查找相似照片") { store.findSimilar() }
                    .buttonStyle(QuietPrimaryButtonStyle()).disabled(store.busy || store.scanning || store.refreshing)
                Text("相似候选，请逐张确认").font(.subheadline).foregroundStyle(Palette.secondary)
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
                    }.padding().paperCard(radius: 22)
                }
            }.padding()
        }.background(canvas).navigationTitle("相似照片")
    }
}
