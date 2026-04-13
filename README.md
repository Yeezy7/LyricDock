# LyricDock

<p align="center">
	<img src="https://img.shields.io/badge/GitHub-black?logo=github&style=flat-square" alt="GitHub"/>
	<img src="https://img.shields.io/badge/_macOS-blue?style=flat-square" alt="Platform"/>
	<img src="https://img.shields.io/badge/license-GPLv3-orange?style=flat-square" alt="License"/>

</p>

<p align="center">
	<img src="https://img.shields.io/github/v/release/Yeezy7/LyricDock?style=flat-square" alt="Version"/>
</p>

<p align="center">
	<a href="README_cn.md"><b>中文</b></a> •
	<a href="README.md"><b>English</b></a>
</p>

<p align="center">
	<strong>LyricDock</strong> is a macOS menu bar lyric companion. It is a pure menu bar app with no main window dependency, supports right-click menu controls for menu bar width, launch at login, and automatic update checks, automatically scrolls very long lyric lines, is compatible with macOS 26, and supports multiple music apps.
</p>

## 🌟 Features

- Supports right-click menu controls for menu bar width, launch at login, automatic update checks, and quitting
- After a track switch, it first shows `Song Title · Artist`, then switches to lyrics
- Very long lyric lines scroll automatically
- Filters out non-target playback sources (such as web pages) to avoid abnormal menu bar takeover

## ⬇️ Currently Supported Playback Sources

- Apple Music
- Spotify
- Soda Music
- NetEase Cloud Music
- QQ Music

Notes:

- Apple Music / Spotify use dedicated control pipelines
- Soda Music / NetEase Cloud Music / QQ Music prefer system now playing adaptation

- Lyrics are sourced from `LRCLIB`
- Supports LRC timeline parsing
- Supports 14-day lyric caching
- Uses player-provided artwork first; falls back to song matching when unavailable

## 👋 Download & Installation

👉 Download from [GitHub Releases](https://github.com/Yeezy7/LyricDock/releases)

🌿 If you run into any issues, please submit them via [issues](https://github.com/Yeezy7/LyricDock/issues)

## 🔑 License

This repository is currently licensed under the `MIT License`. See [LICENSE](LICENSE).

