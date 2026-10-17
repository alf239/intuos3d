# intuos3d

> **Status (October 2026): parked.** OpenTabletDriver 0.6.8-rc1 and later ship a native Apple Silicon build that
> reads this tablet and delivers pressure, so for most people that is the better-supported choice; see
> [design_notes.md](design_notes.md#phase-0a-opentabletdriver) for what was tested with it and the one Krita
> issue found. intuos3d still works as described below and remains useful as a 500-line reference for the
> Intuos 3 protocol and for posting tablet events from a user-space driver on macOS.

A small, native macOS driver for the **Wacom Intuos 3** graphics tablet. It gives you pen pressure, tilt, the
eraser end, the two pen buttons, all eight ExpressKeys and both Touch Strips on current macOS, including
Apple Silicon, where Wacom's own driver stopped working years ago.

Tested on a PTZ-630 (6×8") with macOS 27 on an Apple Silicon Mac, in Krita and Tayasui Sketches. It runs as a
background launch agent, uses only public macOS APIs (no kernel extension), and is about 500 lines of Swift.

> Other Intuos 3 sizes (PTZ-430, 930, 1230, 1231W) speak the same protocol but the active-area size is currently
> hard-coded for the 6×8. See [Other models](#other-models).

## Requirements

* A Mac running macOS 13 or newer (Intel or Apple Silicon).
* Xcode Command Line Tools, for the Swift compiler. If `swift --version` says "command not found", run
  `xcode-select --install`.
* The tablet connected by USB. No other tablet driver (Wacom's, OpenTabletDriver) running at the same time.

## Install

```bash
git clone https://github.com/alf239/intuos3d.git
cd intuos3d/intuos3d
./install.sh
```

The script builds the driver, installs it to `~/Library/Application Support/intuos3d/`, and starts it as a
launch agent so it runs at every login. It also creates a local code-signing certificate on first run; this is
what lets macOS remember the permissions below across updates.

### Grant two permissions

macOS shows two dialogs for `intuos3d` right after installation:

1. **Input Monitoring**: needed to read the tablet. Until granted, the log says `Input Monitoring permission missing`.
2. **Accessibility**: needed to move the cursor and deliver pressure to apps.

Allow both. The driver notices the Input Monitoring grant within a few seconds and opens the tablet by itself.

If no dialog appears, add it by hand: System Settings → Privacy & Security → **Input Monitoring** → "+" →
press ⌘⇧G in the file dialog and paste `~/Library/Application Support/intuos3d/intuos3d`. Repeat under
**Accessibility**. Then restart the driver:

```bash
launchctl kickstart -k gui/$UID/local.intuos3d
```

### Check it works

```bash
tail -5 ~/Library/Logs/intuos3d.log
```

You want to see `tablet attached: PTZ-630` and `mode switch: ... -> Intuos mode`. Move the pen over the tablet:
the cursor should follow. For pressure, open a drawing app with a pressure-sensitive brush. Krita (free) has a
built-in checker under Settings → Configure Krita → Tablet Settings → "Open Tablet Tester".

## Defaults

| Control | Default |
|---|---|
| Pen tip | left button, with pressure and tilt |
| Lower pen button | right click |
| Upper pen button | middle click |
| Eraser end | reported as an eraser; apps decide what to do with it (Krita: pick an eraser preset once while the eraser end is active, it then remembers) |
| ExpressKeys 1–4 (left) | hold Shift, Option, ⌘, Space |
| ExpressKeys 5–8 (right) | ⌘Z, ⌘⇧Z, `[`, `]` (undo, redo, Krita brush smaller/larger) |
| Left Touch Strip | scroll |
| Right Touch Strip | ⌘- / ⌘= (zoom out / in) |
| Mapping | whole tablet maps to the main display, keeping the screen's aspect ratio |

The tablet is in "mouse mode" until the driver switches it over, so the cursor moves even with the driver stopped;
only pressure and the buttons need the driver.

## Configuration

Settings live in `~/Library/Application Support/intuos3d/config.json`, created with the defaults on first run:

```json
{
  "expressKeys": ["shift", "option", "cmd", "space", "cmd+z", "cmd+shift+z", "[", "]"],
  "leftStrip":   ["scroll:-1", "scroll:1"],
  "rightStrip":  ["cmd+-", "cmd+="],
  "mapping": "fit",
  "penButton1": "right",
  "penButton2": "middle",
  "pressureGamma": 1,
  "logReports": false
}
```

| Key | Meaning |
|---|---|
| `expressKeys` | One action per key, held down for as long as the key is pressed (so modifiers work as modifiers). |
| `leftStrip`, `rightStrip` | Two actions: the first fires when your finger slides **down** the strip, the second when it slides **up**, once per segment. |
| `mapping` | `"fit"` keeps the screen's aspect ratio using the largest centred area of the tablet; `"stretch"` uses the whole tablet surface. |
| `penButton1`, `penButton2` | `"right"`, `"middle"`, `"left"` or `"none"` for the lower and upper pen buttons. |
| `pressureGamma` | Pressure curve: `1` linear, below 1 softer (reaches full pressure sooner), above 1 firmer. |
| `logReports` | `true` writes every tablet packet to the log; useful for finding out which key is which. |

**Actions** are written as key chords: any of `cmd`, `shift`, `option`, `ctrl` joined with `+` to one key name
(`a`…`z`, `0`…`9`, `[`, `]`, `;`, `'`, `,`, `.`, `/`, `\`, `-`, `=`, `space`, `tab`, `return`, `escape`, `delete`,
`left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`…`f20`), a modifier on its own
(`"shift"`), `"scroll:N"` to scroll N lines (negative scrolls the other way), or `"none"`.

After editing, restart the driver:

```bash
launchctl kickstart -k gui/$UID/local.intuos3d
```

**Which ExpressKey is which?** The entries follow the tablet's internal numbering, which on the left block is not
top-to-bottom. Set `"logReports": true`, restart, press a key and look for `pad(buttons: N)` in the log: N is 1, 2,
4, 8 for entries 1–4 and 16, 32, 64, 128 for entries 5–8. Turn logging off afterwards.

## Updating and uninstalling

Update: `git pull` and run `./install.sh` again. Permissions carry over.

Uninstall:

```bash
./uninstall.sh
```

This stops the driver and removes its files, launch agent and config. Unplug and replug the tablet to put it back
into plain mouse mode. The `intuos3d` rows in Privacy & Security and the "intuos3d local code signing"
certificate in Keychain Access can be deleted by hand if you like.

## Troubleshooting

Everything the driver does is in `~/Library/Logs/intuos3d.log`.

* **`IOHIDManagerOpen failed: 0xe00002e2`**: Input Monitoring is not granted to this exact build. Check the row
  in System Settings is ticked; if you see an old `intuos3d` row that does nothing, remove it with "−", restart
  the driver and allow the new dialog.
* **Cursor moves but no pressure in any app**: Accessibility is not granted, or the app does not support tablet
  events. Krita's Tablet Tester tells you what arrives.
* **Cursor moves like a mouse, no `Intuos mode` line**: the driver is not running (`launchctl print gui/$UID/local.intuos3d`)
  or another tablet driver has the device.
* **Permissions lost after reinstalling**: the install was signed ad-hoc because the certificate could not be
  created (the script prints a warning). Re-grant both permissions; it will not happen again once the certificate
  exists.
* **Right-click menus pop up while drawing**: your grip is pressing the lower pen button; set `penButton1` to
  `"none"` or `"middle"`.
* **Strip scrolls the wrong way**: swap the two entries of `leftStrip`.

## Other models

The report format is shared by all Intuos 3 tablets, but the maximum X/Y values are fixed to the 6×8's 40640×30480
in `Sources/intuos3d/Protocol.swift` (`maxX`, `maxY`), and the USB product ID `0x00b1` is matched in
`main.swift`. For another size, change those three numbers (Linux's `wacom_wac.c` lists them: 4×5 = 25400×20320,
9×12 = 60960×45720, 12×12 = 60960×60960, 12×19 = 97536×60960) and run `./install.sh`. Reports with the
`logReports` option on, from any model, are welcome as issues.

## How it works, and why not the alternatives

[design_notes.md](design_notes.md) has the full story: what OpenTabletDriver and the patched Wacom driver do and
don't do on today's macOS, the tablet's USB/HID layout, the report format, how the events are posted so that apps
see pressure, and the verification logs.

## License

MIT, see [LICENSE](LICENSE).
