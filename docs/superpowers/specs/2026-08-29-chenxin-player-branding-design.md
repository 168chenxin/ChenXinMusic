# 称心播放器 1.0.0 品牌与发布规格

## 目标

将应用面向用户的品牌从 Beans Music 改为“称心播放器”，发布首个正式版本 `v1.0.0`，并保留既有 GitHub Release 自动更新流程。

## 已确认范围

- 平台图标使用用户提供的原图，不裁切、不重绘。
  - 网易云音乐：`WangYiYunMusic.png` -> `BrandNetease.imageset/icon.png`
  - QQ 音乐：`QQMusic.png` -> `BrandQQ.imageset/icon.png`
  - 酷狗音乐：`KuGouMusic.png` -> `BrandKugou.imageset/icon.png`
  - 汽水音乐：`QiShuiMusic.png` -> `BrandSoda.imageset/icon.png`
- 将用户可见的 Beans Music 名称替换为“称心播放器”，包括应用显示名、应用内文案、更新页、README、更新日志、Release 名称与 IPA 文件名。
- 更新仓库统一改为 `168chenxin/ChenXinMusic`。检测最新 Release、按 `.ipa` 后缀选择下载附件、自动下载与手动检查的控制流不变。
- 删除我的页面的交流群入口、Telegram 跳转、交流群二维码界面，以及无其他调用的二维码资源；移除当前更新日志中的相关条目。
- `MARKETING_VERSION` 设为 `1.0.0`。CI 仍在构建时自动递增 `CURRENT_PROJECT_VERSION`。

## 兼容性边界

- 保留 Xcode target `Beans`、`com.beans.app` Bundle ID 和 UserDefaults 键，确保覆盖安装与已有设置保持兼容。
- 不修改应用主图标，因为用户未提供新的主图标资源。
- 仅清理对当前用户可见的品牌、交流群和更新入口；不改动第三方平台名称及其版权说明。

## 验证

- 回归脚本覆盖版本、更新仓库、品牌资源、社区入口移除和平台图标映射。
- 运行 `Tests/RegressionChecks.ps1` 与 `git diff --check`。
- 推送到新仓库后，由现有 GitHub Actions macOS 工作流执行 Xcode 编译、打包和 v1.0.0 Release 验证。
