# 上游 Release 自动同步设计

## 目标

让 `168chenxin/ChenXinMusic` 定期检查原作者 `XIaodou0416/Beans-Music` 的最新稳定 Release；发现新版本后，将上游代码合并到本仓库 `main`，保留已有定制，并触发本仓库现有的无签名 IPA 构建和 Release 发布流程。

App 内更新检查继续只请求 `168chenxin/ChenXinMusic` 的 Release，不改回原作者仓库。

## 方案

新增 `.github/workflows/sync-upstream.yml`：

1. 通过 GitHub Releases API 读取上游最新稳定 Release（`/releases/latest`，不跟踪预发布版本）。
2. 读取仓库内 `.github/upstream-release` 记录的已同步标签；标签未变化时结束，不产生提交。
3. 标签变化时 fetch 对应 tag，并在 `main` 上执行普通三方合并。合并成功后写入新的上游标签。
4. 合并后检查关键定制仍存在：App 名称“称心播放器”、汽水音乐资源/代码、Logo 资源，以及 `UpdateChecker.repoPath = "168chenxin/ChenXinMusic"`。任一检查失败则任务失败，不推送结果。
5. 以带 `[skip ci]` 的同步提交推送 `main`，避免 `push` 触发重复构建；随后通过 `workflow_dispatch` 调用现有 `build-unsigned-ipa.yml`，设置 `publish_release=true`。
6. 构建工作流从合并后的 `project.yml` 读取版本号，生成同版本的 `ChenXinMusic-unsigned.ipa` 并发布到本仓库对应 Release。构建号仍由现有 CI 递增。

工作流触发方式：每 6 小时定时运行，也支持手动触发。使用 `GITHUB_TOKEN` 完成读取、推送和触发构建，不新增长期密钥。

## 定制保留边界

上游代码通过 Git 三方合并进入当前 `main`，当前分支已有提交自然保留。以下内容作为同步后的硬性校验：

- `project.yml` 中的显示名仍为“称心播放器”；
- `Beans/Assets.xcassets/BrandSoda.imageset` 及汽水音乐 Swift 实现仍存在；
- `Beans/UpdateChecker.swift` 的仓库路径仍为 `168chenxin/ChenXinMusic`；
- 自有仓库的更新地址、说明文档和 Logo 不被上游替换。

若上游与定制修改发生无法自动解决的冲突，工作流停止并输出冲突文件，不自动选择任一侧。人工解决并推送后，下次同步可继续。

## 版本与状态

`.github/upstream-release` 只保存最后一次成功同步的 Release 标签，例如 `v1.5.6`。同步后的 App 版本沿用上游 Release 版本；首发版本 `v1.0.0` 保持现状，后续上游版本按其标签发布到自有仓库。

## 验证

- PowerShell 回归检查确认同步工作流、状态文件和关键定制校验逻辑存在。
- YAML 静态检查确认 schedule、workflow_dispatch、权限、`[skip ci]` 和构建触发参数正确。
- 在 GitHub Actions 手动运行同步工作流：无新 Release 时不提交；模拟新标签时完成合并、推送并触发 IPA 构建。
- 观察构建工作流成功完成，并确认自有仓库 Release 的标签和 IPA 资产与上游版本一致。
