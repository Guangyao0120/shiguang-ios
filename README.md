# 拾光 · iPhone 本地相册整理

原生 SwiftUI / PhotoKit / Vision 工程，最低 iOS 17。直接使用系统照片图库，不复制原图到独立图库。默认本地整理，v0.2 新增可选 DeepSeek API，不使用第三方 SDK。

## 运行

1. 将整个文件夹传到 Mac，用 Xcode 16 或更新版本打开 `Shiguang.xcodeproj`。
2. 选择 Shiguang target → Signing & Capabilities → 选择自己的 Team，并将 Bundle Identifier 改成唯一值。
3. 连接 iPhone，开启开发者模式，选择手机运行。首次启动授权照片读取和修改权限。
4. 也可以先在模拟器里导入少量测试照片，再运行。可在 Xcode 的 Product → Test 执行单元测试。

已在 GitHub Actions 的 macOS / Xcode 16.4 环境完成模拟器构建及 13 项 XCTest（0 失败），并另外完成真机 Release archive 与未签名 IPA 打包。[查看真机包构建](https://github.com/Guangyao0120/shiguang-ios/actions/runs/42586125067)。真实 iPhone 的签名、安装、图库操作与 DeepSeek 实际调用尚未验收。`Shiguang-iPhone-unsigned.ipa` 是 iOS/arm64 真机包，但需要在 Windows 签名工具中用你自己的 Apple 账户签名后安装，不能直接点开安装。

## GitHub 云端构建

工程已上传到私有仓库 [Guangyao0120/shiguang-ios](https://github.com/Guangyao0120/shiguang-ios)。打开仓库的 Actions → iOS build and tests → Run workflow，选择 main 即可手动构建。修改 App、Tests、Xcode 工程或工作流并推送 main 也会自动构建。

绿色 success 表示构建和测试通过。运行详情底部的 Artifacts 包含 `Shiguang-Simulator` 与 `Shiguang-Build-Reports`，保留 7 天。前者只用于 Mac 上的 iOS 模拟器，不能装进真实 iPhone；后者是编译日志与 XCTest 报告。构建不需要 DeepSeek Key 或苹果签名证书，测试使用虚构 Key 和响应夹具，不会产生 DeepSeek 调用费用。GitHub Actions 自身计算用量按账户额度计费。

新增 `iphone` job 依赖模拟器测试通过后执行：生成 `Shiguang-iPhone-IPA-unsigned` 与 `Shiguang-iPhone-Reports`，保留14天。真机包已验证 Mach-O arm64、平台 iOS（不是 iOSSimulator）及 SHA-256。用 Sideloadly 等 Windows 签名工具可尝试以免费 Apple 个人账户签名安装；账户验证和手机信任/开发者模式需要用户本人操作，免费签名通常7天到期。不要把 Apple 密码或验证码放进 GitHub Secrets。

## DeepSeek 接入（v0.2）

安装 App 后：底部「AI」→右上角齿轮→粘贴自己的 DeepSeek API Key→「保存到本机钥匙串」→「测试连接」。测试只发送固定短句，会有少量 API 消耗。不要把 Key 发到聊天或写入源码；Key 不进入 JSON 数据库、UserDefaults 或压缩包。

- 官方 HTTPS 接口固定为 `https://api.deepseek.com/chat/completions`，默认模型 `deepseek-flash`，可编辑模型名。不支持随意填写代理地址，避免误发密钥。
- 照片详情 →「用 DeepSeek 深入识别」：预览本次 OCR 文字，可选发送最长边 1024px、去除元数据的压缩 JPEG；点击确认后才调用 API。模型输出标签和摘要，再手动应用。普通视频只发送封面及封面文字，不发送音视频流。
- 底部「AI」：输入一句话，仅发送该指令，不发送图库目录或照片。AI 返回分类、OCR、人物、行程等筛选条件，App 在本地求交集；你核对匹配照片后才能创建系统相册。
- v0.2 不支持日期推理、排除/OR 筛选、自动认人或视频语音理解；模型明确返回不支持项时停止匹配。筛选依赖已有本地标签/人物/行程，不能保证找全。
- 401/402/429、网络超时、空输出、截断或非法标签均有失败提示，不自动重试、不自动删除。离开 AI 界面取消本地等待，不保证撤销服务端已经发生的费用。
- 启用云端识别后，**你确认发送的内容会离开手机并交给 DeepSeek**。不上传未选择的图库；本地扫描不调用 API。隐私 manifest 包含可选云端功能的图片和用户内容传输声明，上架前仍需结合服务商实际条款核对 App Store 隐私标签。
- API 接口已按当前官方文档实现；没有收到真实 Key，尚未做真实账户联调。请在手机上测试连接。已通过的请求/返回夹具 XCTest 不能代替真实 API 联调。

官方参考：[调用方式](https://api-docs.deepseek.com/)、[图片输入](https://api-docs.deepseek.com/guides/vision/)、[JSON 输出](https://api-docs.deepseek.com/guides/json_mode/)。

## 每张照片的 Tag（v0.3）

- 每张照片都有分类入口；尚未分类或所有类别被取消时，显示「待确认」，不编造详细标签。
- 缩略图下显示最多两个标签及其余数量，详情显示所有关联标签，包括分类、自由内容标签、已命名人物和行程。比如 `#桐桐 #中秋长沙 #人像 #夜景`，它们引用同一张照片。
- 照片详情可以手动添加自由标签（最多40个，每个24字，逗号/顿号/分号分隔），去掉重复、空白和前导 #，大小写不重复；移除标签不删除原图。本地扫描不覆盖自由标签。
- 首页「我的标签」点击筛选，也可以直接搜索标签。人物和行程标签通过各自关联管理，不重复建立另一套身份信息。
- DeepSeek 识别结果增加至多12个自由内容标签的建议，先预览再应用；例如物体、活动、场景、商品品类，不能随意猜测身份、地点或敏感属性。不自动对整库调用计费 API。
- AI 整理支持按已有自由标签精确匹配，多标签取 AND；它不会在匹配时偷偷分析或上传全部照片。
- 所有标签保存在 App 本地整理数据库，**不是写进原图文件，也不保证出现在苹果照片的关键词中**。卸载 App 会丢失 App 私有标签，当前还没有独立标签导出/恢复功能。原图不会因为移除标签而删除。
- 数据字段采用可选值，v0.2 本地记录可以继续读取；标签清理、存储与匹配测试已在 iOS 模拟器通过。

## 第一版功能

- 读取全部或有限授权的系统图库；本地缩略图分析，默认禁止从 iCloud 下载。云端独有素材显示为待下载，不假装已分析。
- Vision 中英文 OCR、面部检测、图像分类；结合文字与界面线索给出聊天、视频通话、商品、收据、发票、支付、票券、表情/梗图等可重叠分类。分类是启发式建议，不是高精度训练模型。
- 手动修改标签；自动扫描不会覆盖手工增删标签。
- 人像检测与手动命名人物，支持给多张照片关联同一个人物。**当前没有自动识别“同一个人”的人脸身份模型**。
- 用拍摄时间和经纬度聚合「出游候选」，允许改名为「中秋 · 长沙」。地点必须来自素材定位；缺少定位的照片可手动加入行程。**不会自动猜出长沙或中秋，也不能调用苹果照片内部的人物/旅行识别结果。**
- 相同照片可以出现在多个分类、人物和行程中，引用同一张原图；可将当前分组创建为系统相册。
- 64 位感知哈希筛选疑似相似照片，提供对比与单张待删。不是文件级精确查重，不自动选择或删除，可能有漏检误检。
- 上滑加入 App 内待删队列，连续下一张；撤销、恢复、重启持久化，最后批量请求系统删除。取消或失败保留队列，成功后再清理本地记录。
- 视频展示时长、播放原视频、加入行程和人物。当前扫描仅分析视频封面，**未实现语音转录、整段视频理解、祝福对象提取**。
- 搜索 OCR、标签、人物和行程名称；支持中文短语和关键词组合。**不是通用自然语言模型**。

## 隐私与删除语义

本地分析文字、分类及待删状态写到 App 的 Application Support，采用 iOS 文件保护。读取图库图片默认禁止 iCloud 网络下载；部分素材需要先在苹果照片中下载。可选 DeepSeek 请求只在用户主动确认时发送预览内容。API Key 保存为仅本机、解锁时可访问的钥匙串项目。没有请求通讯录、麦克风或定位权限（只读取照片已有定位），没有后台持续扫描或隐形上传。

上滑只是改变本 App 的队列，不释放存储空间，也不影响苹果照片。最终「请求系统删除」会弹出 iOS 确认；真实照片删除后进入系统「最近删除」。如果开启了 iCloud 照片，系统删除会同步到其他设备。App 不会绕过系统确认，不会自行清空系统最近删除。

原图移除后，各栏目中的引用都会消失；移除标签或从行程中移除只影响分类。可撤销最近一次加入待删，不等于能撤销已经提交给系统的删除。

## 使用顺序

建议先仅授权 20–100 张测试素材：聊天长截图、付款截图、视频通话截图、收据、票券、梗图、人像、带定位的旅行照片、相似照片和短视频。点击「本地扫描」，检查建议并修正。进入任一分组后点「连续整理」，上滑放入待删，最后从「待删」页集中审核。

进入「人物」创建桐桐，打开照片详情即可关联；行程页点 + 设置名称和日期范围创建行程，照片详情可补充成员。

## 验证状态

- Windows：工程结构、plist、资源 JSON、源文件语法解析与交付清单检查（见 `VALIDATION.md`）。
- Apple 平台：GitHub macOS 云端 build/test 已通过，13 项测试 0 失败；权限、删除取消、Live Photo、iCloud-only、扫描中断、内存和耗电仍需真机验收。

## 源码

`App/Models.swift` 数据与分类规则；`LocalAnalyzer.swift` 本地 Vision；`LibraryStore.swift` 相册操作、持久化和扫描；`Views.swift` 界面；`DeepSeekClient.swift` API、钥匙串与返回结果校验；`AIViews.swift` 设置、发送预览及整理草稿；`Tests/RulesTests.swift` 本地规则、状态与 API 请求/返回夹具测试。

开发参考：[PhotoKit](https://developer.apple.com/documentation/photokit)、[Vision OCR](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)、[删除请求](https://developer.apple.com/documentation/photos/phassetchangerequest/deleteassets(_:))。
