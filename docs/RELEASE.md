# LyricDock 发布说明

这份说明对应当前的 `LyricDock 1.0` 菜单栏版本。

## 发布定位

- 当前版本更适合 **官网直装 / GitHub Releases / 测试分发**
- 不建议直接按 **Mac App Store** 方向发布

原因：

- 应用会读取系统 now playing 和播放器自动化能力
- 当前工程包含 `MediaRemoteAdapter` 这条更接近系统媒体会话的适配链路
- 这条路线更适合独立分发，而不是先按 App Store 审核约束收口

## 发布前准备

1. 在 Xcode 里确认 `LyricDock` 和 `LyricDockWidget` 使用同一个 Team
2. 确认 `App Group` 已正确配置
3. 确认主应用与 Widget 的 Bundle ID 已固定
4. 如果准备正式分发，确保本机已有 `Developer ID Application` 证书
5. 首次真机运行时，确认 Apple Events 权限弹窗正常

## 快速生成本地 Release 包

直接运行：

```bash
./scripts/release_build.sh
```

输出位置：

- `build/release/LyricDock.app`
- `build/release/LyricDock-<version>-<build>-unsigned.zip`

这个模式适合：

- 自测
- 发给少量内测用户
- 先验证 Release 构建是否稳定

## 生成签名归档包

先把 `scripts/ExportOptions-DeveloperID.plist` 里的 `YOUR_TEAM_ID` 改成你自己的 Team ID，然后运行：

```bash
TEAM_ID=YOUR_TEAM_ID EXPORT_OPTIONS_PLIST=./scripts/ExportOptions-DeveloperID.plist ./scripts/release_build.sh
```

输出位置：

- `build/release/LyricDock.xcarchive`
- `build/release/export/LyricDock.app`
- `build/release/LyricDock-<version>-<build>.zip`

## 推荐的发版检查清单

1. 菜单栏封面、歌词、上一首/暂停/下一首是否正常
2. `Apple Music / Spotify / 汽水音乐 / 网易云音乐 / QQ 音乐` 是否按预期切换
3. 网页音频是否不会错误接管菜单栏
4. 歌词未命中时是否回退到 `歌名 · 歌手`
5. 右键菜单里的宽度调节、开机自启、退出是否正常
6. Widget 是否能从共享数据读取内容

## 公证建议

如果准备给更多用户分发，建议在导出签名包后继续做 notarization。常见流程是：

1. 用 `notarytool submit` 提交 `.app` 或 `.zip`
2. 等待 Apple 返回成功结果
3. 对最终 `.app` 执行 `stapler staple`
4. 重新打包上传 Releases

证书和公证凭据都属于你本机环境，我这边没有办法替你直接完成这一步，但脚本和目录结构已经给你留好了。
