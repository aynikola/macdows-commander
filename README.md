# Macdows Commander

A native two-panel file manager for macOS, in the spirit of Windows Commander. Written in Swift and AppKit, keyboard first, with FTP, SSH, editors and an image tool built in.

**English** · [Türkçe](README.tr.md)

![Macdows Commander: file panels, terminal, code editor and image tool](docs/images/hero.jpg)

## Features

### Two panels, driven by the keyboard

- `Ins` or `Space` marks, `Shift`+click marks a range, `Ctrl+A` marks everything
- `F5` copies, `F6` moves, `F7` makes a folder, `Shift+F7` makes a text, HTML or Markdown file, `F8` deletes
- A file that already exists is never replaced without asking, and you can rename the copy instead
- `F2` opens the same folder in the other panel, and the path box at the bottom takes a pasted path
- `⌘1`, `⌘2` and `⌘3` sort by name, size and date
- Drag files in from Finder, or out to it
- Search by name and content, browse zip and tar archives, keep favorite folders
- `F11` opens the Mac's share menu, and `⌥F3` compares two files

### Servers

FTP, FTPS, SFTP and SCP, with saved connections. SSH logins can use a password, a `.pem` key, or another server as a hop for machines that only accept certain addresses. Passwords are kept in the Keychain.

![Saved servers, one connecting through a gateway](docs/images/servers.jpg)

### Code editor (F4)

Colors for HTML, CSS, JavaScript and PHP, with syntax errors shown on their line. Find and replace, go to line, duplicate and delete lines, Save As. Encodings and line endings are kept as they were.

![Code editor showing a PHP syntax error on its line](docs/images/code-editor.jpg)

### Writing editor (F10)

Write directly on the page in HTML or Markdown, with the source one key away. The toolbar shows the format at the cursor, tables gain and lose rows and columns, and pasted text keeps only what the toolbar can make: other tags, attributes and scripts are removed.

| | |
|---|---|
| ![Writing editor](docs/images/writer.jpg) | ![Colored boxes in the writing editor](docs/images/writer-boxes.jpg) |

### Viewer and image tool (F3)

Pictures open at their real size. Crop, change the image or canvas size, rotate, flip, and add text with a color and a shadow. Save as PNG, JPG or WebP. PDF pages open too, and can be saved as images. HTML and Markdown files show as pages or as source; scripts in them don't run.

| | |
|---|---|
| ![Adding text with a shadow](docs/images/image-text.jpg) | ![Cropping a picture](docs/images/image-crop.jpg) |

![Markdown shown as a page](docs/images/markdown-preview.jpg)

### Compare files

Two files side by side and lined up, with changed, added and removed lines in color. Each side shows its size and date, and says which file is newer.

![Two versions of a file compared](docs/images/compare.jpg)

### Terminal

A terminal under the panels, with a row of Git buttons. Commands that only look run at once. Those that change something wait for you to press Enter.

![Terminal with Git buttons](docs/images/terminal-git.jpg)

### Themes

Default dark, Light, Cream and Windows Commander, from the View menu, with a choice of fonts and sizes.

| | |
|---|---|
| ![Default dark theme](docs/images/theme-default-dark.jpg) | ![Light theme](docs/images/theme-light.jpg) |
| ![Cream theme](docs/images/theme-cream.jpg) | ![Windows Commander theme](docs/images/theme-windows-commander.jpg) |

Press `⌥F1` in the app for every shortcut and the manual, in English or Turkish.

## Build

Needs macOS 13 or newer and the Swift toolchain.

```bash
scripts/build-app.sh
open "build/Macdows Commander.app"
```

If F keys change the brightness or volume on your Mac, press them with `Fn`, or turn on standard function keys in System Settings.

## Test

```bash
swift test
```

The tests against live servers are skipped unless `MC_TEST_DIR` is set. See `scripts/test-servers.sh`.

## Built with

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal and [libwebp](https://github.com/SDWebImage/libwebp-Xcode) for saving WebP.

The screenshots use a sample folder and made-up servers. The photo is [Pink mountain sunset](https://commons.wikimedia.org/wiki/File:Altm%C3%BCnster_-_Pink_mountain_sunset.jpg) by simon, under CC0.

## License

[MIT](LICENSE)
