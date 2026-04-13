# LyricDock

LyricDock 是一个 macOS 菜单栏歌词播放器伴侣。当前版本会在顶部菜单栏显示：

- 当前歌曲封面
- 歌名 / 歌手 / 实时歌词
- 上一首 / 播放暂停 / 下一首

## 当前形态

- 纯菜单栏应用，不依赖主窗口
- 支持右键菜单调节菜单栏宽度、开机自启、自动检查更新和退出
- 切歌后会先显示 `歌名 · 歌手`，再切到歌词
- 超长歌词会自动滚动显示
- 过滤网页等非目标播放源，避免菜单栏被异常接管

## 当前支持的播放源

- Apple Music
- Spotify
- 汽水音乐
- 网易云音乐
- QQ 音乐

其中：

- Apple Music / Spotify 走专用控制链路
- 汽水音乐 / 网易云音乐 / QQ 音乐 优先走系统 now playing 适配

## 歌词与封面

- 歌词来自 `LRCLIB`
- 支持 LRC 时间轴解析
- 支持 14 天歌词缓存
- 封面优先使用播放器自身 artwork，拿不到时再回退歌曲匹配

## 打开与运行

1. 用 Xcode 打开 [LyricDock.xcodeproj](/Users/ikun/Documents/code/Projects/APP/LyricDock/LyricDock.xcodeproj)
2. 给 `LyricDock` 和 `LyricDockWidget` 配置你自己的 Signing Team
3. 确认 Widget 所需的 `App Group` 已配置一致
4. 首次运行时，允许应用访问播放器自动化能力
5. 直接运行主应用，菜单栏即会出现播放器条

## 本地构建

已通过以下命令验证：

```bash
xcodebuild -project LyricDock.xcodeproj -scheme LyricDock -configuration Debug -derivedDataPath /tmp/LyricDockDerivedData CODE_SIGNING_ALLOWED=NO build
```

## 发布

第一版发布材料已经整理好：

- 发布脚本：`./scripts/release_build.sh`
- DMG 导出脚本：`./scripts/export_dmg.sh`
- Developer ID 导出模板：`./scripts/ExportOptions-DeveloperID.plist`
- 发布说明：`./docs/RELEASE.md`

快速生成一个本地 Release 包：

```bash
./scripts/release_build.sh
```

导出一个可分发的 `.dmg`：

```bash
./scripts/export_dmg.sh
```

如果你有自己的 `svg` 软件图标，可以直接导入并覆盖当前 AppIcon：

```bash
./scripts/import_svg_icon.sh /path/to/icon.svg
```

## 开源准备

- 工程已经去掉个人 `Team ID` 绑定，克隆后可直接换成自己的签名团队
- `.gitignore` 已忽略 `build/`、归档包和本地 Xcode 产物
- GitHub Release 文案模板见 [docs/GITHUB_RELEASE_TEMPLATE.md](/Users/ikun/Documents/code/Projects/APP/LyricDock/docs/GITHUB_RELEASE_TEMPLATE.md)

## 许可证

当前仓库使用 `MIT License`，见 [LICENSE](/Users/ikun/Documents/code/Projects/APP/LyricDock/LICENSE)。

## 备注

当前版本更适合独立分发，不建议直接按 Mac App Store 路线收口。更具体的发布步骤见 [docs/RELEASE.md](/Users/ikun/Documents/code/Projects/APP/LyricDock/docs/RELEASE.md)。
