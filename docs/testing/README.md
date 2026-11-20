# 可复现测试

## 无设备自动检查

```sh
python3 -m unittest discover -s scripts/tests -v
scripts/test-java.sh
scripts/test-swift.sh
python3 fixtures/generate.py .build/fixtures/run-001 --mib 4
```

Java 使用 JDK 17；脚本使用 Java 8 目标语言级别编译四个纯 Java 测试入口。Swift 使用项目基线 Xcode、macOS 26 与 libusb。合成生成器不访问设备，不覆盖已有目录，产物全部写入忽略的 `.build`。原始页面仅为格式头样例，不是有效的汉王手写页面，不能用于验证页面解码质量。

## 构建

```sh
scripts/build-app.sh
scripts/build-android.sh
```

Android 构建需要 SDK platform 34、build-tools 34.0.0 及原签名材料；私有口令配置见 SECURITY.md。Mac 构建复用本机签名身份和钥匙串组件，不包含在 CI 公共任务内。

## 真机验收

自动检查不启动 ToolboxCheck，不连接 USB、Wi-Fi 或用户设备。真机操作单独选择隔离合成目录，记录连接方式、应用版本、预期和实际结果；不把原始日志、真实内容、账号或设备身份写入仓库。

已完成的内容导出、快照续传、源变化隔离、来源移除和清理范围见 [验收记录](../content-export-progress.md)。24 小时自然过期、低空间和真实笔记资源闭包仍不视为已验收。测试结束后仅清理本次创建且已核对的文件，保留用户数据与已有配对。

## 隐私检查

提交检查读取 Git 暂存区中的完整文件内容，工作区脱敏不能替代暂存区检查；推送检查读取可达历史及提交邮箱。扫描报告只输出位置和规则。自动检测不是完整身份识别系统，需要人工检查姓名、上下文和附加资源。

GitHub 配置参考官方 [checkout](https://github.com/actions/checkout) 和 [setup-java](https://github.com/actions/setup-java) 文档，动作固定到核对后的提交。未来启用远程前先将仓库设为私有，并配置 main 的评审与检查要求。
