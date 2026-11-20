# 仓库架构与版本管理

采用单仓库：Sources/HanvonToolbox 管理 SwiftUI 与应用状态，ToolboxCore 管理设备、传输、同步及内容导出，CHanvonUSB 与 CSQLite 为桥接层，ToolboxCheck 为真机诊断程序；android 管理伴侣实现及 Java 测试。保留 Swift Package 的当前目录，避免仓库初始化同时进行模块迁移。

协议契约放 docs/protocol，真机与自动化说明放 docs/testing，合成样例生成器放 fixtures。旧功能设计与验收文档保留原链接。`.build` 里的临时设备操作脚本和原始取证不纳入版本控制，必要的测试能力通过纯合成生成器重建。

main 只保存可构建基线；功能、修复和文档使用短期分支。首次提交只记录当前工作快照，不补造之前的开发历史。

当前基线应用元数据：Mac 0.3.2（构建 9），伴侣 0.7.1（版本代码 13）。无线原文件协议 2；内容能力 protocol=1，快照能力通过 snapshotDownloads 协商。这些版本用途不同，不因建立 Git 仓库强行统一。

组件发布标签分别使用 macos/v… 与 companion/v…；基线标签仅表示仓库快照，不表示所有设计功能或所有设备均已验收。当前完成情况见内容导出开发进展。

发布前区分编译测试、签名验证与真机验收。现有 libusb 配置以 Apple Silicon Homebrew 安装布局为基线；配置完整 macOS CI 时须匹配 macOS 26、Xcode SDK 与 libusb，再验证环境可复现性。当前 GitHub 检查仅包含隐私、Java 和合成样例生成，尚未运行远程任务，未自动接入签名与真机设备。
