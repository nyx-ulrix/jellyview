# JellyView (beta)

> **Heads up: this app is fully vibe coded.** It was built by prompting an AI coding agent, not hand-written.
> It works on my devices, but expect rough edges. Use at your own risk.

JellyView is an Android player for [Jellyfin](https://jellyfin.org), forked from [Fladder](https://github.com/DonutWare/Fladder).

## What's different from Fladder

- **Netflix-style look:** dark theme with a red accent, hero banner (Liked, Next up or Continue watching), 16:9 thumbnails.
- **Player gestures:** each one can be turned on or off.
  - Edge swipes change brightness and volume.
  - Hold for 2x speed.
  - Swipe across the screen to seek.
- **Audio boost and subtitle delay** in the player.
- **Subtitles:**
  - Picked automatically by keyword ("eng", "English", ...).
  - No more doubled subtitles.
- **Streams:** auto pause and resume when the buffer runs out (never for downloads).
- **Downloads:**
  - Pick the quality.
  - Watched episodes are deleted automatically.
  - The next episodes of shows you're watching download automatically.
  - Downloads stay available offline, including when Tailscale is off.
- **Selection:** long-press to select several episodes or downloads.
- **Get tab:** search for and request movies and shows from a companion media-stack dashboard.
- **Updates:** checks this repo's releases and installs new versions in the app.

## Install

Download the APK from [Releases](../../releases) and open it on your Android device.
When a new release is out, JellyView shows "JellyView x.y.z is available". Tap **Update**, then **Install**.
The first time, Android asks you to allow installs from JellyView.

## Build

Flutter 3.47:

```
flutter build apk --release --flavor production --target-platform android-arm64
```

## License

GPL-3.0, same as Fladder. See [LICENSE](LICENSE).
