# 开发与提交

本仓库同时管理 Mac 工具箱、Android 伴侣和无线协议。当前仅在本地初始化；创建远程仓库时先选私有，公开和许可证另行决定。

## 初次设置

```sh
git config --local core.hooksPath .githooks
git config --local user.name 'Hanvon Toolbox Contributors'
git config --local user.email 'contributors@hanvon-toolbox.invalid'
```

Git 钩子不会随 clone 自动启用，需执行上述设置。提交身份使用项目名和不可投递地址，避免个人邮箱或账号进入提交元数据。

## 工作流程

1. 从 main 创建短期 feat/、fix/ 或 docs/ 分支。
2. 修改相关源码、测试及协议或使用文档，保持一个提交解决一个问题。
3. 执行相关测试；具体命令见 [测试说明](docs/testing/README.md)。
4. 仅暂存明确审阅的文件；运行 `python3 scripts/privacy-check.py --staged --identity`，人工审阅 `git diff --cached`。
5. 提交后运行 `python3 scripts/privacy-check.py --history`；通过后才推送。签名材料、真实设备资料和个人配置一律保留本地。

隐私规则详见 [AGENTS.md](AGENTS.md) 和 [SECURITY.md](SECURITY.md)。自动检查没有能力识别所有姓名、个人文件内容或新式密钥，人工审阅不可省略。CI 会拒绝包含个人邮箱的提交历史，后续删除文件也不能清除旧历史中的敏感值。

## 发布

Mac、伴侣分别维护版本和组件标签；协议版本只在接口契约确有变化时更新。发布说明列出两端兼容组合、真机范围和未验证场景。安装包放入经过核对的发布附件，不放在 Git 对象库中。当前没有配置远程、发布凭据或自动发布任务。
