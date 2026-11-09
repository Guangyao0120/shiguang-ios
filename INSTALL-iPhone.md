# 拾光：把 IPA 安装到自己的 iPhone

这是为真实 iPhone 构建的 arm64 安装包，不是模拟器文件。

文件：`Shiguang-iPhone-unsigned.ipa`，481,912 字节，最低 iOS 17.0。

构建：[GitHub Actions 成功运行](https://github.com/Guangyao0120/shiguang-ios/actions/runs/42586125067)。已重新通过模拟器测试、真机 Release archive、arm64/iOS 平台检查、IPA 完整性检查。下载到本地后另行解析 Mach-O 与 Info.plist 复核通过。

SHA-256：`b4f11ab6be52ae1ab1bd58b4fa1f661fff6aa61b973235a9cb34b15a975d57a4`。

**包名包含 unsigned，表示还没有用你的 Apple 账户签名。不能直接在 iPhone「文件」里点开安装。** 需要在 Windows 上用签名安装工具处理一次。无需购买开发者会员或越狱；免费账户通常 7 天有效，之后要续签。

## 你需要准备

- 一台 Windows 电脑、一根能传输数据的 USB 数据线、解锁的 iPhone。
- 你自己的 Apple 账户；登录或验证码请在工具中自行输入，不要发到聊天、上传仓库或写入代码。
- Windows 签名安装工具，例如 [Sideloadly 官方网站](https://sideloadly.io/)。只从官方来源下载。按工具提示准备 Apple 设备驱动及其支持的 iTunes / iCloud 版本；如果现有软件有冲突，先核对提示，不要随意卸载。

## 安装步骤

1. 在 Windows 下载本次 `Shiguang-iPhone-unsigned.ipa`。
2. 安装并打开签名工具，将 iPhone 接到电脑，保持手机解锁；手机提示时选择「信任此电脑」并自行输入锁屏密码。
3. 在工具里选中你的 iPhone，加载 IPA，输入自己的 Apple 账户，开始签名安装。
4. 如果工具要求 Apple 密码、二次验证码或账户验证，由你本人完成。不要将这些信息填入 GitHub Secrets，也不用提供给我。
5. iPhone 如果提示开发者不受信任，在「设置 → 通用 → VPN 与设备管理」核对自己的开发者账户后进行信任；具体菜单以当前 iOS 为准。
6. 如果提示需要开发者模式，按手机指引在「设置 → 隐私与安全性 → 开发者模式」开启并重启，重启后的确认由你完成。
7. 打开「拾光」，先只授权少量测试照片。检查读取、扫描、修改标签、退出重开后保存是否正常，再逐步扩大授权。
8. DeepSeek 位于底部「AI → 右上角齿轮」。自行粘贴 Key 到钥匙串并测试；本地扫描不需要 Key。

工具可能因 Apple 账户状态、服务变化或驱动而失败，当前尚未对你的手机签名或安装，不能保证一步完成。出现错误时提供不含密码/验证码/Key 的报错文字即可继续排查。

## 有效期与升级

- 免费 Apple 个人开发签名的描述文件通常 7 天过期。使用相同 Apple 账户和相同应用标识刷新/覆盖安装，不要为了续签先卸载 App。
- 标签、人物名字、行程修正与待删队列当前保存在 App 的本地数据库。卸载会丢失这些私有整理记录；原照片仍在系统图库。
- 上滑只加入 App 内待删；真正删除照片时 iOS 会确认，取消后保留队列。真实删除会影响启用了 iCloud 照片的其他设备。

## 已验证与未验证

模拟器编译与 13 项单元测试已通过。真机 IPA 另外检查目标平台为 iOS、CPU 架构为 arm64、包内含 Payload/Shiguang.app 以及压缩包完整性。真正的签名、安装、照片权限、删除确认、耗电和 DeepSeek 实际调用仍需连接手机后验收。

官方参考：[Apple 免费个人开发账户限制](https://developer.apple.com/help/account/basics/about-your-developer-account/)、[Sideloadly 使用与有效期说明](https://sideloadly.io/faq)、[AltStore Windows 安装与开发者模式说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)。
