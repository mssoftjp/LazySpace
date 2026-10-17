# LazySpace

Automatic window tiling for the Mac you already have.

Open LazySpace and keep working. The windows in each Space line up on their own, and Spaces, Mission Control, and full screen stay exactly as they are. There is nothing new to learn and nothing to configure. LazySpace just takes window arrangement off your hands.

[日本語](README.ja.md) · [Guide](docs/guide.md) · [Releases](https://github.com/mssoftjp/LazySpace/releases)

## Why LazySpace

LazySpace was inspired by AeroSpace. Once your windows are tiled, there is no going back to dragging and resizing them by hand, and AeroSpace does tiling very well. It also asks a fair amount in return: its own workspaces, a set of shortcuts to learn, and a way of working that can take some getting used to.

LazySpace keeps the good part and lowers the bar. It runs on top of the Spaces macOS already gives you, so Mission Control, full screen, and Split View keep working as they always have. Windows are tiled on their own, and you can keep using the mouse all day. The shortcuts are there whenever you want them.

## Install

```bash
brew install --cask mssoftjp/tap/lazyspace
```

Or download the DMG from [Releases](https://github.com/mssoftjp/LazySpace/releases) and drag LazySpace.app to Applications.

1. Open LazySpace. Its icon appears in the menu bar.
2. macOS asks for access. Turn on LazySpace in System Settings › Privacy & Security › **Device Control and Data Access** (**Accessibility** before macOS 27).
3. That is all. Go back to what you were doing.

LazySpace needs macOS 14 or later and Apple Silicon. To build it yourself, see [Build from source](docs/guide.md#build-from-source).

## What it does while you work

**Windows are tiled on their own.** Work in a Space as usual, and the windows there are arranged to share the work area. A new window joins beside the one you were using. When you close a window, the others take over its place.

**Each Space has its own layout.** To leave a Space alone, uncheck **Automatically Arrange This Space** in the menu. To leave an app alone, add it in Settings › Apps.

**Several displays work the way you expect.** The menu lists the Spaces of each display under the display's name, and you can send a window to a desktop on another display from the menu.

## What it never does

- It never creates workspaces of its own, and it never hides windows off screen.
- It never changes how your Mac switches Spaces. It uses the macOS shortcut **Switch to Desktop N**, a window or app that is already on the destination, or the Mission Control shortcuts for moving one Space left or right. It reads those settings and does not write them.
- It never saves window titles, and it never records what you type.
- It never connects to the network, except to check GitHub for updates (once a day, unless you turn that off, or when you ask) and to download an update you choose to install.

## Keyboard, mouse, or command line

The mouse is enough for everyday use. Drag the edge between two windows to resize them, or drop a window onto another to swap their places.

When you want more, the shortcuts are ready. Many of the defaults are the same as AeroSpace's, so your fingers may already know them. Hold a modifier key for about a second to see the full list, and change them in Settings › Shortcuts.

| Keys | Action |
|---|---|
| `⌥H` `⌥J` `⌥K` `⌥L` | Focus the window on the left, below, above, or right |
| `⌥⇧H` `⌥⇧J` `⌥⇧K` `⌥⇧L` | Move the window in that direction |
| `⌥Z` | Zoom the window to fill the work area, or restore it |
| `⌥F` | Take the window out of tiling, or put it back |
| `⌥1` … `⌥9` | Switch to Desktop 1–9 |
| `⌥⇧1` … `⌥⇧9` | Send the window to Desktop 1–9 and stay here (needs macOS 27). A setting in Settings › Shortcuts takes you there with it |
| `⌥⇥` | Go back to the previous Space |

Everything the shortcuts do is also a command:

```bash
lazyspace focus left
lazyspace space 2
lazyspace move-to-space 3 --follow
lazyspace list-windows      # which windows are tiled here, and why not
lazyspace status            # what LazySpace is doing, and the latest result
```

Add `--json` for structured results that scripts and AI agents can read. Each result says whether the operation finished or stopped partway, and why. See [Scripting and agents](docs/scripting.md).

## Learn more

The [guide](docs/guide.md) covers the menu bar, every shortcut, Settings, app rules and hooks in the configuration file, binding modes, updates, differences from AeroSpace, troubleshooting, and privacy.

## License

[MIT](LICENSE)
