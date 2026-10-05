# X Media Assist for Safari

[日本語](README.md) | English

A Safari extension that saves videos and animated GIFs from X to your Mac’s Downloads folder. Videos are saved as MP4, and animated GIFs as GIF.

> [!IMPORTANT]
> Use this software only for content you have the right or permission to save and use.
> Follow applicable laws and each service’s terms of use.

## Requirements

- macOS 14 or later
- A Mac with Apple Silicon (Intel Macs are not supported)

## Installation

### Option 1: Homebrew

If you have [Homebrew](https://brew.sh/) installed, run:

```bash
brew install --cask jemielttf/tap/x-media-assist
```

To update:

```bash
brew update
brew upgrade --cask jemielttf/tap/x-media-assist
```

### Option 2: GitHub Releases

1. Download `X-Media-Assist-<version>.zip` from the [releases page](https://github.com/jemielttf/X-MediaAssist-safari/releases).
2. Unzip the file.
3. Move **X Media Assist.app** to your Applications folder.

## Getting started

After installing with either method:

1. Open **X Media Assist.app**.
2. Click **Open Safari Extension Settings** and enable **X Media Assist**.
3. Allow access to `x.com` and `cdn.syndication.twimg.com` in the Safari profile you use.

The interface supports Japanese and English. The extension follows Safari’s language; the companion app follows its macOS app language. English is the fallback when no supported language matches. There is no language selector in the app.

## Saving videos

### From a post

1. Open a post on X containing a video or animated GIF in Safari.
2. Click **↓ Save Video** in the post.
3. Keep the tab open until the save result appears.

### From a post URL

If no save button appears in the post, use its URL:

1. Click **X Media Assist** in Safari’s toolbar.
2. Enter a post URL, such as `https://x.com/username/status/postID`. If the current tab is a post on X, its URL is filled in automatically.
3. Choose a save format, then click **Save Video**.
4. Keep the popup open until the save result appears.

| Save Format | Saved files |
| --- | --- |
| Auto (default) | Videos as MP4; animated GIFs as GIF |
| MP4 | Both videos and animated GIFs as MP4 |

The save button in a post always uses Auto.

## What can be saved

Files are saved to your Mac’s Downloads folder. Existing files are never overwritten; a different filename is used if the name is already taken.

| Content | Support |
| --- | --- |
| Videos and animated GIFs in public posts | Supported |
| Private, deleted, or restricted posts | Not supported |
| Still images and live streams | Not supported |

## Animated GIFs

- X delivers animated GIFs as video. This app **converts** that video into a GIF; it does not retrieve the original uploaded GIF file.
- If GIF conversion fails, the app **saves the MP4 instead** and shows the reason. This can happen when:
  - The video is longer than 30 seconds.
  - The input or output file exceeds 100 MiB.
  - Resolution or frame count limits are exceeded, or conversion takes too long.
  - Another GIF conversion is already in progress.

## GIF settings

Adjust quality and file size with these three settings:

| Setting | Options | Default |
| --- | --- | --- |
| Quality | High / Medium / Low | High |
| Max Frame Rate | 30 / 25 / 20 / 15 fps | 20 fps |
| Output Size | 100% / 75% / 50% | 100% |

**To make a smaller file, lower one or more of these settings.**

### Where to change them

- **Companion app:** Your default settings. Changes are saved automatically.
- **Safari toolbar popup:** Temporary settings for downloads made from that popup. They do not change your defaults. Reopening the popup restores the default settings.

GIF settings are not used when MP4 is selected.

### How the settings work

**Max Frame Rate** limits the number of frames while preserving their original timing. It does not convert the video to a fixed frame rate.

- A 30 fps video with a 20 fps limit is reduced to approximately 20 fps.
- A 15 fps video with a 20 fps limit keeps its frame count; no frames are added.
- Frame intervals may vary. Very short frame durations and other timing adjustments can result in fewer frames than the selected limit suggests.

**Output Size** scales both width and height. Orientation is applied first, then the image is reduced while preserving its aspect ratio.

| Original video | 75% | 50% |
| --- | --- | --- |
| 1280 × 720 | 960 × 540 | 640 × 360 |

## Companion app

While running, the app shows an icon in the menu bar. Closing the window keeps the app running. Use the menu to reopen the window or quit.

The menu also offers:

- **Hide Dock Icon**
- **Launch at Login:** Keep the app in a permanent location, such as Applications, before enabling this.

## Troubleshooting

**“Could not confirm the save result”:** Check Downloads before trying again. The file may already have been saved.

**“The extension disconnected” or a similar message:** Check Downloads first. If the file was not saved, reload the page and try again. If the problem continues, quit and reopen Safari, then check that the extension is enabled.

**No save button in a post:** Open the extension from Safari’s toolbar and enter the post URL.

**While saving:** Keep the tab or popup open until the result appears. Closing it early prevents you from seeing the result.

**An MP4 was saved instead of a GIF:** Check the conditions under “Animated GIFs” above. The reason is also shown after saving.

## Building from source

Source code is available in the [GitHub repository](https://github.com/jemielttf/X-MediaAssist-safari).

To build from the same source as a distributed release, use the release tag listed on the releases page. Xcode and Rust are required. See the [developer README (Japanese)](README_DEV.md#起動) for cloning, signing, and build instructions.

## License

Released under AGPL-3.0-or-later. See [LICENSE](LICENSE) and [third-party notices](Licenses/THIRD_PARTY_NOTICES.txt).
