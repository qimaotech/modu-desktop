# GitHub CI 与本地打包

[macOS CI](../.github/workflows/ci.yml) 在 `main` 分支 push、`v*` tag push、所有 PR 和手动运行时执行。需要仓库启用 GitHub Actions，无需配置 Secrets。

使用 [GitHub 的 `macos-26` runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 和 [预装 Xcode 26.6](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)，按 `Package.resolved` 下载依赖：

1. 运行 `ModuDesktopTests` 单元测试；失败时上传 `.xcresult`，保留 7 天。UI 测试保持单独运行。
2. 通过 [打包脚本](../script/package_app.sh) 构建 Release App，App 和内嵌 `modu-cli` 都仅包含 `arm64`，面向 Apple Silicon。
3. 检查 App、CLI、内置 skill、架构与 ad-hoc 签名，并运行 CLI `--version`。
4. 用系统 `hdiutil` 生成并校验 `Modu-arm64.dmg`，内含 `Modu.app` 和指向 Applications 的快捷方式；上传 DMG，保留 14 天。
5. `v*` tag push 触发的运行在测试和打包成功后创建 GitHub Release，上传同一次运行的 DMG，并自动生成发布说明。独立的发布 job 使用 GitHub 自带 token 与 `contents: write` 权限。

CI 使用 `-parallel-testing-enabled NO` 避免多个 Git 子进程密集测试争用 runner；单个测试内部的并发与取消检查仍会执行。

在 GitHub 仓库的 **Actions → macOS CI → 对应运行 → Artifacts** 下载 DMG；打开后将 `Modu.app` 拖到 Applications。仅支持 Apple Silicon，最低系统版本沿用工程设置，当前为 **macOS 26.5**。

这是测试包，采用无需证书的 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证，下载后可能需要在系统设置的“隐私与安全性”中允许打开。正式签名、公证和自动升级不在当前 [PRD 范围](PRD.md)；后续正式签名分发需提供 Developer ID Application 证书、私钥和公证凭据。GitHub Release 发布不会改变安装包的签名状态。

发布版本前，先将工作流改动提交并推送到 `main`。在要发布的提交上创建并推送版本 tag，例如：

```bash
git tag v0.1.0
git push origin v0.1.0
```

成功后从仓库的 **Releases → 对应版本 → Assets** 下载 DMG。普通分支 push、PR 和手动运行只生成 Actions 产物；单独推送 tag 也不会自动修改 App 或 CLI 的内部版本号，发布前需同步更新工程的 `MARKETING_VERSION` 和 CLI 的版本声明。

每个版本 tag 只发布一次；已发布版本再次运行创建 Release 会失败，发布新版本时使用新 tag。

本地打包从仓库根目录运行：

```bash
./script/package_app.sh
```

产物为 `build/package/Modu-arm64.dmg`。可通过 `MODU_PACKAGE_DIR` 指定产物目录，通过 `MODU_DERIVED_DATA_PATH` 指定 Xcode 构建目录；CI 复用同一脚本。

本地构建与启动验证继续使用 `./script/build_and_run.sh --verify`。
