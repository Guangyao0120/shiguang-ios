import SwiftUI
import UIKit

struct AISettingsView: View {
    @AppStorage("deepseekModel") private var model = "deepseek-flash"
    @State private var key = ""
    @State private var saved = APIKeyStore.hasKey
    @State private var testing = false
    @State private var result = ""
    @State private var testTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("你的 DeepSeek") {
                LabeledContent("接口", value: "api.deepseek.com")
                TextField("模型名称", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(saved ? "已保存 · 填写新 Key 可替换" : "粘贴 API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button("保存到本机钥匙串") {
                    do { try APIKeyStore.save(key); key = ""; saved = true; result = "密钥已保存，没有写入工程或相册数据库。" }
                    catch { result = error.localizedDescription }
                }.disabled(key.isEmpty || testing)
                Button(testing ? "正在测试…" : "测试连接（少量计费，无照片数据）") {
                    testing = true; result = ""
                    testTask = Task {
                        defer { testing = false }
                        do {
                            try await DeepSeekClient(model: model).test()
                            result = "连接成功。文字接口可用；图片支持需在照片详情中测试。"
                        } catch { if !Task.isCancelled { result = error.localizedDescription } }
                    }
                }.disabled(!saved || testing)
                Button("移除 API Key", role: .destructive) {
                    do { try APIKeyStore.delete(); saved = false; key = ""; result = "密钥已从本机移除。" }
                    catch { result = error.localizedDescription }
                }.disabled(!saved || testing)
            } footer: {
                Text("推荐模型 deepseek-flash。接口固定为 DeepSeek 官方 HTTPS 地址，密钥只保存在此设备解锁时可访问的钥匙串。")
            }
            if !result.isEmpty { Section("状态") { Text(result).textSelection(.enabled) } }
            Section("什么时候联网") {
                Text("本地扫描不调用 API。只有你点击 AI 请求或测试连接时才联网，调用费用由你的 DeepSeek 账户承担。")
                Text("照片 AI 可只发 OCR 文字，也可额外发送一张去除元数据、最长边 1024 像素的缩略图。每次先预览再发送。聊天、支付等截图可能含个人信息，请检查预览。")
                Text("AI 整理仅发送你输入的指令，不发送整个图库、人物列表、定位或相册目录。返回条件在手机上筛选，只有你确认后才创建相册。")
                Text("不会自动重试请求。离开 AI 页面会取消等待，但已被服务端接收的请求仍可能计费。")
                Link("DeepSeek 官方接口文档", destination: URL(string: "https://api-docs.deepseek.com/")!)
            }
        }.navigationTitle("AI 设置").navigationBarTitleDisplayMode(.inline)
            .onDisappear { key = ""; testTask?.cancel() }
    }
}

struct AIPhotoView: View {
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deepseekModel") private var model = "deepseek-flash"
    let id: String
    @State private var includeImage = false
    @State private var preparedText = ""
    @State private var preparedJPEG: Data?
    @State private var ready = false
    @State private var running = false
    @State private var suggestion: AISuggestion?
    @State private var errorText = ""
    @State private var requestTask: Task<Void, Never>?
    var record: MediaRecord? { store.state.records[id] }
    var body: some View {
        NavigationStack {
            Form {
                Section("本次发送内容") {
                    Toggle("额外发送图片缩略图", isOn: $includeImage).disabled(running)
                    Text("默认只发文字。开启后发送压缩缩略图，可能提高聊天、商品和梗图的区分效果。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(preparedText.isEmpty ? "尚未识别到文字；可先运行本地扫描，或开启图片发送。" : preparedText)
                        .font(.footnote).textSelection(.enabled)
                    if includeImage, let preparedJPEG, let image = UIImage(data: preparedJPEG) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        Text("将发送此图 · \(preparedJPEG.count / 1024) KB，不含原图定位元数据。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if includeImage && ready { Text("无法读取本地缩略图，请先在系统照片中下载原件。") }
                    Button(running ? "正在等待 DeepSeek…" : "确认发送并识别（会计费）") { send() }
                        .disabled(!ready || running || !APIKeyStore.hasKey || suggestion != nil
                            || (!includeImage && (record?.text.isEmpty ?? true)) || (includeImage && preparedJPEG == nil))
                    if !APIKeyStore.hasKey { Text("请先到「AI 设置」保存 API Key。") }
                }
                if !errorText.isEmpty { Section("未完成") { Text(errorText) } }
                if let suggestion {
                    Section("AI 建议 · 尚未应用") {
                        Text(suggestion.summary).font(.headline)
                        Text(suggestion.tags.joined(separator: " · "))
                        if let keywords = suggestion.keywords, !keywords.isEmpty {
                            Text(keywords.map { "#" + $0 }.joined(separator: " "))
                        }
                        Text(suggestion.explanation).font(.footnote).foregroundStyle(.secondary)
                        Button("应用分类、内容标签与摘要") {
                            store.applyAI(suggestion, id: id)
                            dismiss()
                        }
                        Text("只增加你确认的分类，不会删除原图、移动文件或自动关联人物身份。")
                            .font(.caption)
                    }
                }
            }.navigationTitle("DeepSeek 深入识别").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { dismiss() } }
        }
        .task {
            guard let record else { return }
            let raw = String(record.text.prefix(8000))
            preparedText = "素材类型：\(record.isVideo ? "视频封面，不含语音" : "照片")\nOCR 文字（最多8000字）：\n" + raw
            if let image = await PhotoAccess.image(id: id, size: CGSize(width: 1024, height: 1024)) {
                let scale = min(1, 1024 / max(image.size.width, image.size.height))
                let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                preparedJPEG = normalized.jpegData(compressionQuality: 0.72)
            }
            ready = true
        }
        .onDisappear { requestTask?.cancel() }
        .onChange(of: includeImage) { _, _ in suggestion = nil; errorText = "" }
    }
    private func send() {
        let text = preparedText
        let jpeg = includeImage ? preparedJPEG : nil
        running = true; errorText = ""
        requestTask = Task {
            defer { running = false }
            do {
                let result = try await DeepSeekClient(model: model).classify(text: text, jpeg: jpeg)
                try Task.checkCancellation()
                suggestion = result
            } catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
    }
}

struct AIOrganizeView: View {
    @EnvironmentObject var store: LibraryStore
    @AppStorage("deepseekModel") private var model = "deepseek-flash"
    @State private var command = ""
    @State private var plan: AIPlan?
    @State private var errorText = ""
    @State private var running = false
    @State private var requestTask: Task<Void, Never>?
    @State private var reviewed = false
    var matches: [MediaRecord] {
        guard let plan else { return [] }
        return store.visibleActive.filter { plan.matches($0, people: store.state.people, trips: store.state.trips) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("用一句话，先生成整理草稿").font(.title2.bold())
                TextField("例如：把桐桐在长沙旅行的人像放一起", text: $command, axis: .vertical)
                    .lineLimit(3...6).padding().background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .disabled(running)
                Text("只发送上面的指令，不上传图库。此版本按已有分类、OCR 文字、人物名、行程名筛选；复杂排除、日期推理和删除操作暂不支持。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button(running ? "正在解析…" : "发送指令给 DeepSeek（会计费）") { generate() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !APIKeyStore.hasKey)
                    if running { Button("取消") { requestTask?.cancel() } }
                }
                if !APIKeyStore.hasKey { NavigationLink("先配置 API Key") { AISettingsView() } }
                if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
                if let plan {
                    Text("整理条件 · 待你审核").font(.headline)
                    Text(plan.explanation)
                    Text("分类：\(plan.tags.isEmpty ? "不限" : plan.tags.joined(separator: "、"))\n文字：\(plan.text.isEmpty ? "不限" : plan.text)\n人物：\(plan.person.isEmpty ? "不限" : plan.person)\n行程：\(plan.trip.isEmpty ? "不限" : plan.trip)")
                        .font(.subheadline).textSelection(.enabled)
                    Text("内容标签：" + ((plan.keywords ?? []).isEmpty ? "不限" : (plan.keywords ?? []).joined(separator: "、")))
                        .font(.subheadline)
                    if !plan.unsupported.isEmpty {
                        Text("暂不支持：" + plan.unsupported.joined(separator: "；"))
                            .foregroundStyle(.orange)
                        Text("请简化指令后重试，不会执行不完整的整理条件。")
                    } else if !plan.hasFilter {
                        Text("没有可用的筛选条件，请更具体地描述。")
                    } else {
                        Text("在手机上匹配到 \(matches.count) 项").font(.headline)
                        MediaGrid(records: matches)
                        Toggle("我已核对以上条件和照片", isOn: $reviewed)
                        Button("创建系统相册「\(plan.albumName)」") {
                            let ids = matches.map(\.id)
                            reviewed = false
                            Task { await store.exportAlbum(name: plan.albumName, ids: ids) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(!reviewed || matches.isEmpty || store.busy || store.scanning)
                    }
                }
            }.padding()
        }.navigationTitle("AI 整理").navigationBarTitleDisplayMode(.inline)
            .toolbar { NavigationLink { AISettingsView() } label: { Image(systemName: "gearshape") } }
            .onChange(of: command) { _, _ in plan = nil; reviewed = false }
            .onChange(of: matches.map(\.id)) { _, _ in reviewed = false }
            .onDisappear { requestTask?.cancel() }
    }
    private func generate() {
        let input = command.trimmingCharacters(in: .whitespacesAndNewlines)
        running = true; plan = nil; reviewed = false; errorText = ""
        requestTask = Task {
            defer { running = false }
            do {
                let result = try await DeepSeekClient(model: model).plan(command: input)
                try Task.checkCancellation()
                plan = result
            } catch { if !Task.isCancelled { errorText = error.localizedDescription } }
        }
    }
}
