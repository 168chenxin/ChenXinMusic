# 上游 Release 自动同步实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 定期将原作者最新稳定 Release 合并到 `168chenxin/ChenXinMusic` 的 `main`，保留本项目定制，并触发现有 IPA Release 构建。

**架构：** GitHub Actions 在 Ubuntu runner 上读取上游 Releases API，比较 `.github/upstream-release`，必要时 fetch 标签并三方合并。合并后验证品牌、汽水音乐资源和自有更新地址，提交带 `[skip ci]` 的同步提交，再 dispatch 现有无签名 IPA 工作流发布对应版本。

**技术栈：** GitHub Actions YAML、Bash、`curl`、`jq`、GitHub CLI、PowerShell 回归检查。

---

### 任务 1：为同步流程建立回归检查

**文件：**
- 修改：`Tests/RegressionChecks.ps1`

- [ ] **步骤 1：添加失败断言**

在现有读取文件区域加入：

```powershell
$sync = Get-Content -Raw -Encoding UTF8 (Join-Path $root '.github/workflows/sync-upstream.yml')
$upstreamState = Get-Content -Raw -Encoding UTF8 (Join-Path $root '.github/upstream-release')
if ($sync -notmatch 'XIaodou0416/Beans-Music') { throw 'Upstream repository regression' }
if ($sync -notmatch 'releases/latest') { throw 'Stable release lookup regression' }
if ($sync -notmatch 'schedule:' -or $sync -notmatch 'workflow_dispatch:') { throw 'Sync trigger regression' }
if ($sync -notmatch '\[skip ci\]') { throw 'Duplicate build prevention regression' }
if ($sync -notmatch 'publish_release=true') { throw 'Release build dispatch regression' }
if ($sync -notmatch 'UpdateChecker.swift' -or $sync -notmatch 'BrandSoda.imageset') { throw 'Customization guard regression' }
if ($upstreamState.Trim() -notmatch '^v1\.5\.5$') { throw 'Initial upstream state regression' }
```

- [ ] **步骤 2：运行检查确认失败**

运行：`pwsh -File Tests/RegressionChecks.ps1`

预期：失败并提示 `PathNotFoundException`，因为同步工作流和状态文件尚未创建。

- [ ] **步骤 3：提交回归检查**

```bash
git add Tests/RegressionChecks.ps1
git commit -m "test: add upstream sync regression checks (task 1/3)"
```

### 任务 2：实现上游 Release 同步工作流

**文件：**
- 创建：`.github/workflows/sync-upstream.yml`
- 创建：`.github/upstream-release`

- [ ] **步骤 1：创建状态文件**

写入当前代码基线对应的上游标签：

```text
v1.5.5
```

- [ ] **步骤 2：添加工作流**

工作流必须包含以下行为：

```yaml
name: Sync Upstream Release

on:
  schedule:
    - cron: '0 */6 * * *'
  workflow_dispatch:

permissions:
  contents: write
  actions: write
```

实现步骤：checkout `main` 且 `fetch-depth: 0`；调用 `https://api.github.com/repos/XIaodou0416/Beans-Music/releases/latest` 并用 `jq` 读取 `tag_name`；校验标签格式；fetch 对应 tag；标签未变化时结束。标签变化时执行 `git merge --no-ff --no-commit --no-edit`；当前已知的单一 `project.yml` 版本冲突保留本地清单，其他冲突输出未合并文件、执行 `git merge --abort` 并失败。合并后检查“称心播放器”、汽水音乐实现和资源、Logo 资源以及 `UpdateChecker.swift` 中的自有仓库路径。通过后将 `project.yml` 的 `MARKETING_VERSION` 更新为去掉前缀 `v` 的上游标签版本，更新 `.github/upstream-release`，用带 `[skip ci]` 的提交推送 `main`，最后运行 `gh workflow run build-unsigned-ipa.yml --ref main -f publish_release=true`。

- [ ] **步骤 3：运行回归检查确认通过**

运行：`pwsh -File Tests/RegressionChecks.ps1`

预期：输出 `Beans regression checks passed.`。

- [ ] **步骤 4：提交工作流**

```bash
git add .github/workflows/sync-upstream.yml .github/upstream-release
git commit -m "ci: sync upstream stable releases (task 2/3)"
```

### 任务 3：静态验证与远端运行验证

**文件：**
- 修改：无

- [ ] **步骤 1：检查工作区差异和 YAML 关键字段**

运行：`git diff --check`；并用 PowerShell 检查工作流包含 `schedule`、`workflow_dispatch`、`contents: write`、`actions: write`、`[skip ci]` 和 `publish_release=true`。

预期：`git diff --check` 无输出，所有字段检查通过。

- [ ] **步骤 2：运行完整回归检查**

运行：`pwsh -File Tests/RegressionChecks.ps1`

预期：退出码为 0，输出 `Beans regression checks passed.`。

- [ ] **步骤 3：推送并手动触发同步工作流**

将实现分支内容推送到自有仓库 `main`，在 GitHub Actions 手动运行 `Sync Upstream Release`。若上游标签仍为 `v1.5.5`，预期工作流报告无变化且不产生同步提交；若上游已有更新，预期完成合并、推送并触发 `Build Unsigned IPA`。

- [ ] **步骤 4：确认构建发布结果**

检查 `Build Unsigned IPA` 运行成功，Release 标签等于上游版本（例如 `v1.5.6`），并包含 `ChenXinMusic-unsigned.ipa` 资产。

- [ ] **步骤 5：提交验证记录**

```bash
git status --short --branch
```

预期：除用户已有的未跟踪 `ci-debug.log` 外无未提交变更。
