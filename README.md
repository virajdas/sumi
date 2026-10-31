# Sumi

A quiet, minimalist Markdown reader for Windows and macOS. Downloads are under 2 MB.

## Download

### Windows

**[Download SumiSetup.exe](https://github.com/virajdas/sumi/releases/latest/download/SumiSetup.exe)** (Windows 10 and 11), then open it and click **Install**.

- No administrator rights needed. Sumi installs just for you, to `%LOCALAPPDATA%\Programs\Sumi`, and adds itself to the Start menu.
- The installer can make Sumi open `.md` files and add a desktop shortcut.
- Windows may show a SmartScreen warning because the installer isn't code-signed. Click **More info**, then **Run anyway**.
- To remove Sumi, use *Settings › Apps*.

### macOS

**[Download Sumi.dmg](https://github.com/virajdas/sumi/releases/latest/download/Sumi.dmg)** (macOS 11 or later, Apple silicon or Intel), open it, and drag **Sumi** to **Applications**.

- macOS blocks the first launch because Sumi isn't signed with an Apple Developer ID. Go to **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
- To remove Sumi, drag it from Applications to the Trash.

All versions are on the [Releases](https://github.com/virajdas/sumi/releases) page.

## Reading

| Action | Shortcut |
| --- | --- |
| Open a file | <kbd>Ctrl</kbd> <kbd>O</kbd>, or drag it onto the window |
| Text size | <kbd>Ctrl</kbd> <kbd>+</kbd> / <kbd>−</kbd> / <kbd>0</kbd>, or <kbd>Ctrl</kbd> + mouse wheel |
| Text & appearance panel | the **Aa** button |
| Appearance (Auto · Paper · Sepia · Night) | <kbd>Ctrl</kbd> <kbd>T</kbd> |
| Next typeface | <kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>F</kbd> |
| Contents | <kbd>Ctrl</kbd> <kbd>\\</kbd> |
| Find | <kbd>Ctrl</kbd> <kbd>F</kbd> |
| Print / PDF | <kbd>Ctrl</kbd> <kbd>P</kbd> |

Ten typefaces, each tuned so they read at the same comfortable size: Literata, Newsreader, Source Serif, EB Garamond, Lora, Bitter (slab), Atkinson Hyperlegible, Nunito (rounded), Figtree and IBM Plex Mono.

Your theme, typeface, text size, contents list and window position are remembered between sessions, in `%LOCALAPPDATA%\Sumi\settings.ini` and `window.txt`. Updating Sumi keeps them; uninstalling removes them.

The page reloads by itself when the file is saved. Relative images and links to other `.md` files work, and web links open in your browser.

The pointer is a small ink dot that grows over things you can click and becomes a slim bar over text. If you prefer your system's normal pointer, switch off **Sumi pointer** under **Aa**.

### On a Mac

The shortcuts use <kbd>⌘</kbd> in place of <kbd>Ctrl</kbd>, and settings live in `~/Library/Application Support/Sumi/settings.ini`. Sumi for Mac is fully native, so text selection, Look Up, Services and VoiceOver work as they do elsewhere on your Mac. A few things differ from Windows:

- Very wide tables wrap their text instead of scrolling sideways. Code blocks still scroll.
- `<video>` and `<audio>` tags don't play.
- Copied text is plain text.

## Building

Requires the .NET SDK (any version that can build `net48`). Run `.\build.ps1` to produce `dist\SumiSetup.exe`.

- `src/Sumi`: the reader. A WinForms host around the system WebView2 (built into Windows 10/11), with the UI in `web/` (embedded into the exe).
- `src/Setup`: the self-contained installer and uninstaller.
- `src/Mac`: the macOS reader, entirely Swift: AppKit and TextKit, with no web view. It shares only the fonts and icon in `src/Sumi/web`. On a Mac with Xcode's command line tools, run `tools/build-mac.sh` to produce `dist/Sumi.dmg`.
- `tools/make-icon.ps1`: renders `assets/sumi.ico`.

Uses [marked](https://github.com/markedjs/marked) (MIT). All typefaces are under the SIL Open Font License 1.1, via [Fontsource](https://fontsource.org). Their licence texts are in [`licenses/`](licenses).
