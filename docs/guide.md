# LazySpace guide

This guide covers LazySpace from installation to the configuration file. For an overview, see the [README](../README.md).

## Install

LazySpace needs macOS 14 or later and Apple Silicon. Install it with Homebrew:

```bash
brew install --cask mssoftjp/tap/lazyspace
```

This installs LazySpace.app and the `lazyspace` command. You can also download the DMG from [GitHub Releases](https://github.com/mssoftjp/LazySpace/releases) and drag LazySpace.app to Applications.

### Build from source

Building requires Xcode 27.

```bash
git clone https://github.com/mssoftjp/LazySpace.git
cd LazySpace
script/build.sh
```

This runs the tests and creates `dist/dev/LazySpace.app`. Move it to Applications and open it. It is signed with your Apple Development certificate when the keychain has exactly one (set `DEVELOPMENT_SIGNING_IDENTITY` to choose); otherwise it is signed ad hoc, and macOS asks for access again after every build.

### The `lazyspace` command without Homebrew

After installing from the DMG or from source, link the command into your `PATH`:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -s /Applications/LazySpace.app/Contents/Resources/bin/lazyspace /usr/local/bin/lazyspace
```

## Getting started

1. Open LazySpace. Its icon appears in the menu bar.
2. The first time, macOS asks for access and Settings › General opens. Click **Open System Settings…** and turn on LazySpace in Privacy & Security › **Device Control and Data Access** (**Accessibility** before macOS 27). You can come back to this later from **Check Windows…** › **Show Fix…** › **Open General Settings**.
3. Go to a Space and keep working. After you stay there for about a second without input, LazySpace tiles its windows. A single window fills the work area (the screen minus the menu bar and Dock).
4. Open more windows. Each one joins beside the window you were using.

If a Space should be left alone, uncheck **Automatically Arrange This Space** in the menu bar while you are on it. If an app should never be tiled, add it in Settings › Apps.

## Everyday use

### Menu bar

| Item | What it does |
|---|---|
| **Move Window to Space** | Sends the focused window to another desktop, on this display or another one. The Space you are on does not change unless **When moving a window to another Space, switch to that Space** is on in Settings › Shortcuts (see the note on other displays below). Shown when there are two or more desktops, except on a full-screen Space |
| **Edit Layout** | Layout actions for the focused window |
| **Automatically Arrange This Space** | Turns automatic arrangement on or off for the current Space |
| **Arrange Now** | Arranges the current Space now and starts tiling it (`⌥⇧A`). It does not change the automatic setting above |
| **Add One Waiting Window** | Adds a window that could not join automatically. Shown only when one is waiting |
| **Pause LazySpace** | Stops all arrangement until you resume. Resuming does not move windows by itself |
| **Check Windows…** | Lists the windows in this Space, whether each one is eligible for tiling, and why not |
| **Settings…** | Opens Settings (`⌘,`) |

The number next to the icon is the desktop you are on. With more than one display, it shows the desktop each display is showing, in the order of the list below, such as `4|1`, and a Space without a number there (a full-screen Space, or one that cannot be read for a moment) shows as `–`. The display you are on is the one with the focused window; it is not marked.

The list at the top of the menu shows your Spaces and the apps in each. With more than one display, both lists are grouped under each display's name as macOS shows it (in System Settings › Displays), and the check mark is on the Space each display is showing. When two displays have the same name, a number in display order is added, such as "LG HDR 4K (1)". Choosing a Space of another display in the top list switches to it. Right-clicking a Space in the top list sends the focused window there, the same as choosing it in **Move Window to Space**.

### Keyboard shortcuts

Hold a modifier key for about a second to see the shortcuts (you can turn this off in Settings › Shortcuts). You can change the shortcuts there too.

| Keys | Action | Name in Settings and the menu |
|---|---|---|
| `⌥H` `⌥J` `⌥K` `⌥L` | Focus the window on the left, below, above, or right | Focus Left, Focus Down, Focus Up, Focus Right |
| `⌥⇧H` `⌥⇧J` `⌥⇧K` `⌥⇧L` | Move the window in that direction | Reorder Left, Reorder Down, Reorder Up, Reorder Right |
| `⌥⌃H` `⌥⌃J` `⌥⌃K` `⌥⌃L` | Swap with the window in that direction | Swap with Window on Left, Swap with Window Below, Swap with Window Above, Swap with Window on Right |
| `⌥⌘H` / `⌥⌘L` | Narrower / wider | Decrease Width / Increase Width |
| `⌥⌘K` / `⌥⌘J` | Shorter / taller | Decrease Height / Increase Height |
| `⌥-` / `⌥=` | Smaller / larger share of its split | Shrink Along Split / Grow Along Split |
| `⌥⇧B` | Balance the layout | Equalize Split Ratios |
| `⌥/` | Switch between side by side and stacked | Switch Horizontal / Vertical |
| `⌥,` | Switch between tiles and accordion | Switch Overlapping / Tiled |
| `⌥F` | Take the window out of tiling, or put it back | Toggle Tiling for Window (in the menu, Remove Window from Tiling or Return Window to Tiling) |
| `⌥Z` | Zoom the window to fill the work area, or restore it | Fill Work Area / Restore Layout (in the menu, Fill Work Area or Restore Tiled Layout) |
| `⌥B` | Focus the previous window | Focus Previous Window |
| `⌥⇧Z` | Undo the last layout change | Undo Layout Change |
| `⌥⇧A` | Arrange this Space now | Arrange This Space (in the menu, Arrange Now) |
| `⌥⇧I` | Add one waiting window | Add One Waiting Window |
| `⌥1` … `⌥9` | Switch to Desktop 1–9 | Switch to Desktop 1 … Switch to Desktop 9 |
| `⌥⇧1` … `⌥⇧9` | Send the focused window to Desktop 1–9 and stay here, or go with it when that is turned on (see Spaces below) | Send Window to Desktop 1 … Send Window to Desktop 9 (Move Window to Desktop 1 and Follow … when turned on) |
| `⌥⇥` | Go back to the previous Space | Switch to Last Used Space |

`⌥` Option, `⇧` Shift, `⌃` Control, `⌘` Command. On some keyboard layouts, Option with a letter types a special character; Settings warns you, and you can pick other keys.

### Mouse

When automatic arrangement is on, you can edit tiled windows with the mouse:

- Drag the edge between two windows to resize them.
- Drop a window onto another tiled window to swap them.
- Drop a window anywhere else to put it back.

### Spaces

- `⌥1`–`⌥9` (or `lazyspace space N`) switch to a numbered desktop, counted in Mission Control order. Full-screen and Split View Spaces are not numbered. With more than one display, numbers count the desktops of each display, and these shortcuts use the display with the focused window.
- `⌥⇧1`–`⌥⇧9` (or `lazyspace move-to-space N`) send the focused window to another desktop while you stay where you are. This needs macOS 27. Add `--follow` on the command line to go with it. To reach a desktop of another display, use the menu or add `--display N` on the command line (the display's position in `lazyspace list-spaces`). macOS gives focus to the window on that display; LazySpace brings back the window that was in front before it so you stay on this display, and if there is none, or it cannot be brought back, focus stays with the sent window.
- To go with the window when you use the shortcuts or the menu, turn on **When moving a window to another Space, switch to that Space** in Settings › Shortcuts (`follow-moved-window` in the file). `⌥⇥` takes you back. The command line is not affected: `lazyspace move-to-space N` always stays, and `--follow` always goes with the window. Before macOS 27, the shortcuts and the menu move a window only with this on: LazySpace holds the window by its title bar while it switches, so the pointer moves for a moment, and a window whose title bar cannot be dragged is not moved.
- Switching uses what your Mac already has: the macOS shortcut **Switch to Desktop N** when it is on, a window or app on the destination, and otherwise the Mission Control shortcuts **Move left a Space** and **Move right a Space** (on by default). LazySpace never changes these shortcuts, and sends nothing when one it needs is off.
- For numbers that do not change, turn off **Automatically rearrange Spaces based on most recent use** in System Settings › Desktop & Dock.
- Pressing a key or the mouse while LazySpace is switching stops the operation.

## Settings

Choose **Settings…** from the menu bar.

- **General**: access, **Open at Login**, language, and notifications.
- **Arrangement**: keeping fixed-size windows next to arranged windows, spacing between windows, where new windows go, and an optional border around the focused window.
- **Shortcuts**: shortcuts for the main mode. Double-click a shortcut or press Return to change it; Delete removes it, Option-Delete restores its default, and **Restore Defaults** resets the whole list. Below the list, a warning appears only when switching to the neighboring Space cannot work, and it says what to change. Above the list, **When moving a window to another Space, switch to that Space** makes the Spaces shortcuts and the menu go with the window they move.
- **Apps**: apps whose windows are never tiled, or kept floating. Each row shows the app's name and its bundle identifier; the name comes from the running app or the installed app, so it is blank for an app that is not installed and for a prefix rule such as `com.microsoft.*`. The identifier is the editable part.
- **Advanced**: the configuration file.
- **About**: the version, a link to the source on GitHub, and updates.

Binding modes and their entry shortcuts are edited only in the configuration file.

Changes are saved as you make them. The language follows macOS unless you choose one.

### Notifications

LazySpace sends no notifications unless you turn them on. Check **Notify when LazySpace needs your attention** in Settings › **General** to get a macOS notification when LazySpace stops arranging windows until you do something: its access is turned off, automatic arrangement stops (for example while Stage Manager is on), or a change to the configuration file cannot be applied. Nothing else sends a notification. When you turn it on, macOS asks once whether LazySpace may send notifications. Choose how they appear (**Temporary** or **Persistent**) in System Settings › Notifications. They make no sound. Clicking a notification opens the place where you fix the problem. A configuration file that is already broken when LazySpace starts is shown in the menu and in Settings, not as a notification.

## Updates

LazySpace checks GitHub for a new version once a day. When one is available, nothing pops up: Settings › **About** shows it with **Update…**, and the menu bar menu shows **Update LazySpace to 0.5.1…** (with the new version). Either opens an alert where you install it, choose **Remind Me Later**, or skip that version. Installing quits LazySpace and reopens the new version; nothing installs on its own. **Check for Updates…** in About checks right away, and also shows a version you skipped. To stop the daily check, uncheck **Automatically check for updates** in About; **Check for Updates…** still works.

A Homebrew installation updates the same way. LazySpace does not check for updates when you build it yourself or open it from the disk image.

## Configuration file

You can change settings in the Settings window or in the file `~/.config/lazyspace/config.toml`. LazySpace reloads the file when it changes. If the file has an error, it is not loaded, and the previous configuration stays in use. Settings keeps your comments and saves the previous version as `config.toml.bak`. A new file is written in English, including its comments. To use another path, set `LAZYSPACE_CONFIG`.

### Common settings

| Setting | Default | Meaning |
|---|---|---|
| `language` | `"system"` | `"system"`, `"en"`, or `"ja"` |
| `gap` | `0` | Space between windows, 0–200 points (rounded to whole points). `[gaps]` sets `inner-horizontal`, `inner-vertical`, `outer-left`, `outer-top`, `outer-right`, and `outer-bottom` separately (each 0–200) |
| `place-dialogs-beside` | `false` | After you switch away from a fixed-size window (such as Calculator or an alert), move it to a strip at the right or bottom edge; arranged windows use the rest |
| `follow-moved-window` | `false` | After a shortcut or the menu moves a window to another Space, switch to that Space too. The command line is not affected |
| `new-window-placement` | `"beside-focused"` | Where new windows join. `"end"` adds them at the end |
| `focus-after-close` | `true` | After the focused window closes, focus a nearby window if no window on this Space has focus |
| `accordion-padding` | `30` | Width of the strip shown for other windows in an accordion, 0–200 points (rounded to whole points) |
| `preferred-minimum` | `[400, 300]` | A size hint (each 0–100000 points) for how many rows to use and for whether a new window fits in the space below a short window. Not an enforced minimum |
| `unknown-floor` | `[120, 120]` | Size assumed when an app does not report a window's minimum size (each 0–100000 points) |
| `quiet-interval` | `0.6` | How long input must be quiet before automatic arrangement starts on a Space and after a mouse drag, in seconds (0.1–10). Ordinary window additions and removals do not always wait this long, and a mouse resize or swap can be adopted sooner once the windows stay still |
| `per-app-timeout` | `2.0` | How long to wait for an app to respond, in seconds (0.2–30) |
| `start-at-login` | not set | Open at Login. When unset, the macOS login item is left as it is |
| `show-shortcut-guide` | `true` | Show the shortcut list after you hold a modifier key for about a second. Shortcuts work either way |
| `[focus-border]` | off | `enabled`, `width` (1–12 points), `color` (`"#RRGGBB"` or `"#RRGGBBAA"`) |
| `[notifications]` | off | `needs-attention`: a macOS notification when LazySpace needs your attention (see Notifications above) |
| `[keys]` | the shortcuts above | Keyboard shortcuts. Set an action to `"none"` to remove its shortcut |

### Example

```toml
gap = 8

# Hooks for status bars. Top-level settings go before any [table].
# Commands run directly; use /bin/sh -c for shell features.
exec-on-space-change = ["/bin/sh", "-c", "sketchybar --trigger space_change"]
exec-on-mode-change  = ["/bin/sh", "-c", "sketchybar --trigger mode_change"]
exec-on-window-sent  = ["/bin/sh", "-c", "sketchybar --trigger window_sent"]

[[rule]]
app = "com.apple.calculator"   # bundle identifier; a trailing * matches a prefix
action = "float"               # keep it where it is; "ignore" leaves it out entirely

[[rule]]
app = "com.google.Chrome"
title = "Meet"                 # optional regular expression for the window title
action = "space"               # send new windows of this app to another Space
space = 3                      # desktop number
follow = false                 # true also switches to that Space

[keys]
zoom = "none"                  # remove a shortcut
space-1 = "f1"
```

Hooks receive details in environment variables: `LAZYSPACE_SPACE_ID` and `LAZYSPACE_PREV_SPACE_ID`, `LAZYSPACE_MODE`, or `LAZYSPACE_WINDOW_ID`, `LAZYSPACE_APP`, `LAZYSPACE_FROM_SPACE`, `LAZYSPACE_TO_SPACE`, `LAZYSPACE_FROM_DISPLAY`, `LAZYSPACE_TO_DISPLAY`, `LAZYSPACE_FROM_SPACE_ID`, and `LAZYSPACE_TO_SPACE_ID`. `LAZYSPACE_FROM_SPACE` and `LAZYSPACE_TO_SPACE` are desktop numbers counted on their own display, and are empty for a Space that has no number; `LAZYSPACE_FROM_DISPLAY` and `LAZYSPACE_TO_DISPLAY` are display positions as in `list-spaces`, and are empty when unknown; the variables ending in `_SPACE_ID` are macOS Space IDs, and `LAZYSPACE_WINDOW_ID` is the window ID. Window titles are never passed. `exec-on-window-sent` runs only after a Space rule sends a window, not after sends from the menu or the command line. Space rules send only windows that open while LazySpace is running.

Hooks run with their own macOS permissions, not LazySpace's Accessibility access. Most commands need none. A hook that should arrange windows can call `lazyspace`.

### Binding modes

Modes are defined only in the file. In a mode, keys without modifiers are allowed.

```toml
[keys]
mode-review = "alt-g"

[mode.review]
return-to-main = true          # go back to the main mode after one command
[mode.review.keys]
mode-main = "esc"
float = "f"
```

The menu bar shows the mode name while a mode other than `main` is active.

### Names for `[keys]`

Actions: `focus-`, `swap-`, `move-`, `join-` followed by `left`, `down`, `up`, or `right`; `focus-back`; `resize-width-grow`, `resize-width-shrink`, `resize-height-grow`, `resize-height-shrink`, `resize-smart-grow`, `resize-smart-shrink`; `balance`, `toggle-split`, `accordion`, `float`, `zoom`, `undo`, `close`, `fullscreen`, `minimize`; `space-1` … `space-9`, `space-next`, `space-prev`, `space-back`; `move-to-space-1` … `move-to-space-9`, `move-to-space-next`, `move-to-space-prev`; `move-to-space-follow-1` … `move-to-space-follow-9`, `move-to-space-follow-next`, `move-to-space-follow-prev`; `arrange`, `integrate`, `pause-resume`, `reload`, `mode-main`, `mode-<name>`.

Keys: `a`–`z`, `0`–`9`, `f1`–`f20`, `minus`, `equal`, `comma`, `period`, `slash`, `semicolon`, `quote`, `backslash`, `backtick`, `leftSquareBracket`, `rightSquareBracket`, `space`, `enter`, `tab`, `esc`, `backspace`, `forwardDelete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageUp`, `pageDown`, `keypad0`–`keypad9`, `keypadDecimal`, `keypadMultiply`, `keypadPlus`, `keypadClear`, `keypadDivide`, `keypadEnter`, `keypadMinus`, `keypadEquals`, `yen`, `underscore`, `eisu`, `kana`, `sectionSign`, combined with `alt`, `shift`, `ctrl`, or `cmd`, for example `alt-shift-h`. Names refer to physical keys. Main-mode shortcuts need a modifier unless they use a function key.

## Command line

```bash
lazyspace status           # what LazySpace is doing, and the latest result
lazyspace list-windows     # windows in this Space, and why any are not tiled
lazyspace arrange
lazyspace focus left
lazyspace space 2
lazyspace move-to-space 3 --follow
```

Run `lazyspace help` for every command. Commands that talk to the app accept `--json` for machine-readable output (`help` and `version` print text only); read the structured fields, because messages follow the display language. Exit codes: `0` completed, `1` refused, partial, or interrupted, `2` could not reach the app. For scripts and AI agents, see [Scripting and agents](scripting.md).

## Coming from AeroSpace

The default shortcuts follow AeroSpace's where LazySpace has the same action. Differences to know:

- **Move** (`⌥⇧` + direction) exchanges places with the neighbor when the two sit next to each other in a split along that direction, and each keeps its share of the split, as in AeroSpace. Otherwise the window is placed beside the neighbor, so sizes change. Moving up or down also lets both windows share the column height again. **Swap** (`⌥⌃` + direction) exchanges two windows' places in the layout.
- **`⌥-` / `⌥=`** change the window's share of its split by 5%, not by a fixed number of points.
- **`⌥1`–`⌥9`** select existing desktops in Mission Control order. A missing desktop is not created.
- There is no built-in service mode. Declare one in the file if you want it. Join has no default shortcut.

## Troubleshooting

- **A window is not tiled.** Choose **Check Windows…**, or run `lazyspace list-windows`. It says why, for example a fixed-size window, a full-screen window, or an app rule.
- **Nothing happens when I press a shortcut.** Run `lazyspace status` and look at **Latest notice**. LazySpace does not show a message when a shortcut is refused.
- **Automatic arrangement is unavailable.** **Check Windows…** shows **Show Fix…** with the setting to change. To hear about it when it happens, turn on the notification in Settings › **General**.
- **`⌥1`–`⌥9` go to the wrong desktop.** Turn off **Automatically rearrange Spaces based on most recent use**.
- **Switching to the next Space does not work.** Check Settings › Shortcuts: it shows a warning with the fix when something is wrong. If it says macOS is not responding, log out of your Mac and back in.
- **A shortcut types a character.** Choose other keys in Settings › Shortcuts.

## Privacy

LazySpace uses Accessibility to read and arrange windows. It reads window titles only to match your rules and does not save them. It counts input events without recording what you type. It keeps no history of what you did: the result of the last operation stays in memory for `lazyspace status`, and only the layout of each Space is saved. LazySpace itself connects to the network only to check GitHub for updates once a day (unless you turn that off in About) and to download an update you choose to install. The check sends the app's name and version and nothing about your Mac or its windows. A notification says only what stopped and what to do; it never contains window titles or the contents of your configuration file. What the commands you configure in hooks do is up to those commands, and they run with their own permissions, not LazySpace's.
