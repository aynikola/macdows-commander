# Macdows Commander

A native two-panel file manager for macOS in the spirit of Windows Commander, written in Swift and AppKit.

- FTP, FTPS, SFTP and SCP, with saved servers
- Built-in code editor with colors and JavaScript and PHP syntax checks
- WYSIWYG HTML editor (F10)
- Image editing in the F3 viewer: crop, image and canvas size, rotation, text with shadow; saves PNG, JPG and WebP, and opens PDF pages
- Saved SSH connections with passwords, key files and jump hosts
- Embedded terminal, archives, search and favorites
- Cream, dark and original color themes
- English and Turkish

Press Option+F1 in the app for the shortcuts and the manual.

## Build

Needs macOS 13 or newer and the Swift toolchain.

```bash
scripts/build-app.sh
open "build/Macdows Commander.app"
```

## Test

```bash
MC_TEST_DIR=<work folder> swift test
```

Without `MC_TEST_DIR` the tests against live servers are skipped. See `scripts/test-servers.sh`.
