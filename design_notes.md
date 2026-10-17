# Design notes: Wacom Intuos 3 PTZ-630 on Apple Silicon macOS

This is the technical report behind `intuos3d`: what was tried, what the tablet looks like on the wire, and how
the driver is built and verified. For installation and everyday use see [README.md](README.md).

Goal: pressure, tilt and ExpressKeys from a Wacom Intuos 3 PTZ-630 (USB `056a:00b1`) on
current macOS (tested host: macOS 27.0.1, Apple Silicon), with the least new code.

**Route that worked: Phase 1, a ~500-line native Swift user-space driver (`intuos3d/`).**
Neither Phase 0 shortcut worked as shipped; details and one correction below.

## Verdict in one table

| Route | Result | Why |
|---|---|---|
| (a) OpenTabletDriver 0.6.7 | ✗ as tested here, but see correction | Has a `PTZ-630.json` config and its 0.6.x macOS backend does post pressure/tilt/eraser/proximity events. The 0.6.7 release is x86_64 only (Rosetta); **0.6.8-rc1 (2026-10-14) ships a native `osx-arm64` build.** The *"No tablets were detected"* result below came from running the daemon directly, which bypasses the UX's permission request. Not yet tested the intended way. |
| (b) thenickdude/wacom-driver-fix 6.3.15-3 | ✗ (not installable unattended) | x86_64-only package that installs a kext, a LaunchAgent, a prefpane and a 2021-era Wacom daemon, requires an admin password and a **restart**, and was built for Catalina–Monterey. The daemon cannot be exercised without the full install (hardened runtime, hard-coded framework path). |
| Phase 1 `intuos3d` | ✓ built, installed, running; waits on two permission grants | Native arm64, IOHIDManager + CGEvent, launch agent, parser verified against the Linux reference with an offline self-test. |

## What the tablet looks like to macOS (from `ioreg`/`hidutil`, dumps in `notes/`)

* One USB configuration, **one HID interface** (class 3, subclass 1 boot, protocol 2 mouse). There is no second
  "pen" interface on the PTZ-630; everything comes over interface 0.
* `MaxInputReportSize = 10`, `MaxFeatureReportSize = 9`, poll interval 4 ms.
* HID report descriptor (`notes/hid-report-descriptor.txt`):
  * **Report 1 (input)**: boot mouse, 3 buttons + relative X/Y/wheel. This is what the tablet sends out of the box,
    which is why macOS moves the cursor with the pen even with no driver, and why Apple's `AppleUserHIDEventDriver`
    binds to it.
  * **Report 2 (input, 9 bytes + ID)**: vendor pen data (Digitizer page, usage 0).
  * **Feature report 2** (1 byte, usage 0x3A, max 2): mode switch. Writing `02 02` puts the tablet in Intuos mode;
    it then stops sending report 1 and sends reports 2 and 12. (Linux `wacom_set_device_mode`; OpenTabletDriver's
    `FeatureInitReport` is the same `02 02`, followed by an extra `04 00` that Linux does not send.)
  * **Report 12 (0x0C, input, 9 bytes + ID)**: ExpressKeys and touch strips.
  * Feature reports 3..13: tool-ID queries etc., not needed.
* Unplugging the tablet resets it to boot-mouse mode.

## Phase 0(a): OpenTabletDriver

* Config exists upstream: `OpenTabletDriver.Configurations/Configurations/Wacom/PTZ-630.json`
  (copy in `notes/opentabletdriver-PTZ-630.json`): 40640×30480, 2046 max pressure (OTD reads the 11-bit raw value,
  Linux halves it to 1023), 8 aux buttons, parser `Intuos3ReportParser`.
* Release assets for v0.6.7 (April 2026): only `OpenTabletDriver-0.6.7_osx-x64.tar.gz`. Both executables in the
  bundle are `Mach-O x86_64`; it runs under Rosetta. **v0.6.8-rc1 (2026-10-14, pre-release) adds
  `OpenTabletDriver-0.6.8-rc1_osx-arm64.tar.gz`, a native arm64 build (ad-hoc signed).**
* Installed to `/Applications/OpenTabletDriver.app` and ran the **daemon directly** under launchd. Log
  (`notes/opentabletdriver-0.6.7-daemon.log`): it enumerated its whole config library and ended with
  `No tablets were detected.` because the process had no Input Monitoring grant. **Correction (from the
  maintainers, issue 2955):** the daemon is not meant to be started that way. `OpenTabletDriver.UX.MacOS/Program.cs`
  runs `PermissionHelper.HasPermissions()` first, which calls `IOHIDRequestAccess` and `AXIsProcessTrusted`, shows
  an alert per missing permission and relaunches the app; the daemon inherits the grants from there. The wiki's
  Required Permissions page also lists both permissions for macOS. The UX instance I launched with `open` was
  almost certainly waiting on that alert when I killed it. So the honest summary is "not tested the intended way",
  not "fails silently".
* Correction to an earlier draft of this README: `master` (the unreleased 0.7 rewrite) has a macOS pointer that only
  posts plain mouse events, but the **0.6.x branch that the 0.6.7 release is built from does implement tablet
  events** (`MacOSVirtualMouse.cs`: `IPressureHandler`, `ITiltHandler`, `IEraserHandler`, proximity events with the
  Wacom capability mask, tablet-subtype mouse events). So with Input Monitoring + Accessibility granted to
  `OpenTabletDriver.app`, OTD would most likely deliver pressure on this tablet under Rosetta. The reasons it was not
  pursued: no native arm64 release, no permission prompt (HidSharp never calls `IOHIDRequestAccess`, so the failure
  is silent only when the daemon is run on its own), and both drivers cannot run at once. Nothing to upstream:
  `PTZ-630.json` is correct, the permission flow and docs exist, and 0.6.8-rc1 already ships `osx-arm64`. The one
  small thing left would be a log line in the daemon when `IOHIDManagerOpen` returns `kIOReturnNotPermitted`.
* The app is left installed but not running. Remove with `rm -rf /Applications/OpenTabletDriver.app
  ~/Library/Application\ Support/OpenTabletDriver`.

### 0.6.8-rc1 native arm64, tested 2026-10-17

After the maintainers pointed at it (issue 2955), the `OpenTabletDriver-0.6.8-rc1_osx-arm64.tar.gz` build was
installed and launched the intended way, with intuos3d stopped:

* Native `arm64` daemon and UX, ad-hoc signed. The UX requested Input Monitoring and Accessibility itself.
* The PTZ-630 was detected and configured (profile "Wacom PTZ-630", Absolute Mode, default bindings).
* AppKit level (`notes/appkit-eventmon-otd-0.6.8-rc1.log`): point events carry the TabletPoint subtype, pressure
  up to 0.97 and tilt; proximity events are posted for pen (`vendorPointerType 0x802`) and eraser; `deviceID`
  matches between them. Pressure-sensitive strokes worked in Tayasui Sketches.
* **Krita 5.3 did not get tablet events**: its Tablet Tester printed only `Mouse press/move` lines with no
  pressure and no `Pen tip brought near`, i.e. Qt never received the proximity event and fell back to mouse
  handling (Qt drops tablet points whose `deviceID` it has not seen in a proximity event). The likely cause is in
  `MacOSVirtualMouse.PostProximityEvent`: the event is created with `CGEventCreate` and posted without a location,
  so WindowServer delivers it to whatever window is at screen (0,0) instead of the window under the pen.
  intuos3d sets the event location to the pen position and Krita receives its proximity events. OTD also never
  posts a proximity *leave*. Not yet confirmed by capturing the event location; a small upstream fix.

## Phase 0(b): wacom-driver-fix 6.3.15-3 (Rosetta)

Downloaded `Install-Wacom-Tablet-6.3.15-3-patched.pkg` (94 MB, Developer ID "Nicholas Sherlock", notarized 2021-09),
expanded it, and inspected rather than installed, because installing needs an admin password and the package demands
a restart (`onConclusion="RequireRestart"`, `hostArchitecture="x86_64"`, see `notes/wacom-driver-fix-6.3.15-3-Distribution.xml`).

What it contains and what that means on Apple Silicon:

* `/Library/Extensions/Wacom Tablet.kext`: **codeless** kext (`notes/wacom-driver-fix-kext-Info.plist.txt`). Its only
  job is an `IOHIDEventDriver` personality matching `VendorID 1386`, so that Apple's HID event driver does not treat
  the tablet as a mouse. Codeless or not, third-party kexts on Apple Silicon need Reduced Security in Recovery, and
  the driver does not strictly need it because IOHIDManager can read the device alongside Apple's driver.
* `/Library/Application Support/Tablet/WacomTabletDriver.app` and `WacomTabletSpringboard.app`: both thin
  `x86_64`, hardened-runtime signed, so Rosetta is mandatory and `DYLD_*` redirection is blocked.
* `/Library/LaunchAgents/com.wacom.wacomtablet.plist` starts the Springboard, which starts `WacomTabletDriver`
  (this is the Intuos-era equivalent of the Bamboo `PenTabletDriver`).
* `/Library/PreferencePanes/WacomTablet.prefpane`: a System Preferences pane. Third-party prefpanes stopped embedding
  in System Settings in macOS 13; it would open as a legacy pane at best, and the README of the fix notes this pane
  crashes on click and was patched for that.
* Launching the extracted `WacomTabletDriver` under launchd/Rosetta (`notes/wacom-driver-fix-6.3.15-3-launch-attempt.log`)
  dies in `dyld` because `/Library/Frameworks/WacomMultiTouch.framework` is not installed, so "does PenTabletDriver
  launch" can only be answered after a real install.

If you still want to try it yourself: run the pkg (right-click → Open if Gatekeeper complains), restart, touch the
pen to the tablet, then grant **WacomTabletDriver / WacomTabletSpringboard** in both Privacy → Accessibility and
Privacy → Input Monitoring as the fix's README describes. Expect the prefpane to be unusable on macOS 26/27 and the
kext to be refused unless Reduced Security is enabled. Uninstall with the bundled "Wacom Tablet Utility".

## Phase 1: `intuos3d`

### Layout

```
intuos3d/
  Package.swift                  SwiftPM, macOS 13+, links IOKit/CoreGraphics/ApplicationServices
  Sources/intuos3d/
    Protocol.swift               Intuos 3 report parser (from Linux wacom_wac.c INTUOS3 paths)
    Output.swift                 CGEvent emission: proximity + tablet-subtype mouse events, pad → keys/scroll
    Config.swift                 JSON config + key-chord/scroll actions
    main.swift                   IOHIDManager setup, mode switch, permissions, run loop
  LaunchAgent/local.intuos3d.plist
  install.sh / uninstall.sh
tools/eventmon.swift             global NSEvent monitor: shows what AppKit makes of the posted events
notes/                           raw evidence from the triage and the verification session
```

### Protocol, as implemented

All reports are 10 bytes, `d[0]` = report ID.

| Report | Condition | Fields |
|---|---|---|
| 2 | `d[1] & 0xfc == 0xc0` | proximity **enter**; tool id `= d[2]<<4 \| d[3]>>4 \| (d[7]&0x0f)<<16 \| (d[8]&0xf0)<<8`, serial from `d[3..7]`. Eraser = tool id bit 3. 2D mouse = `0x017`, lens cursor `0x097`. |
| 2 | `d[1] & 0xfe == 0x80` | proximity **exit** |
| 2 | `d[1] & 0xfe == 0x20` | "in range", no data |
| 2 | type `(d[1]>>1)&0x0f` in 0..3 | pen: `x = be16(d[2..3])<<1 \| d[9]>>1&1`, `y = be16(d[4..5])<<1 \| d[9]&1`, distance `d[9]>>2`, pressure `((d[6]<<3 \| (d[7]&0xc0)>>5 \| d[1]&1) >> 1)` → 0..1023, tiltX `((d[7]<<1)&0x7e \| d[8]>>7) - 64`, tiltY `(d[8]&0x7f) - 64`, side buttons `d[1]&2`, `d[1]&4`, tip = pressure > 10 |
| 2 | type 8, mouse tool | 2D mouse buttons/wheel from `d[8]` |
| 12 | always | ExpressKeys 1-4 `d[5]&0x0f`, 5-8 `d[6]&0x0f`; strips `((d[1]&0x1f)<<8 \| d[2])` and `((d[3]&0x1f)<<8 \| d[4])` as a one-hot 13-bit finger position |

Not handled: airbrush wheel (type 0x0a), marker-pen rotation (type 0x05), 4D mouse.

### Events posted

* On proximity enter/exit: a `kCGEventTabletProximity` event with vendor `0x056a`, tablet `0x00b1`, pointer type
  pen/eraser/cursor, the Wacom tool id and serial, capability mask (X, Y, buttons, tilt, pressure) and a fixed
  `deviceID`. AppKit turns this into `NSEventTypeTabletProximity`; Qt (Krita) uses it to create the tablet device
  and will **drop pressure for a deviceID it has not seen in a proximity event**, which is why this is mandatory.
* On every pen packet: a `mouseMoved` / `*MouseDown` / `*MouseDragged` / `*MouseUp` CGEvent with
  `kCGMouseEventSubtype = kCGEventMouseSubtypeTabletPoint`, the same `deviceID`, raw tablet X/Y/Z, button mask,
  `kCGTabletEventPointPressure` (0..1, optional gamma), `kCGTabletEventTiltX/Y` (-1..1) and `kCGMouseEventPressure`.
  Tip → left button; side buttons → right / middle by default.
* Tablet → main display mapping: `"fit"` (default) uses the largest centred sub-area of the tablet with the display's
  aspect ratio (on a 4K 16:9 display that is 40640×22860 tablet units); `"stretch"` uses the whole surface.
* ExpressKeys: each key's action is held down while the key is pressed, so modifiers work as modifiers.
  Strips: finger movement to a higher/lower segment fires the first/second action once per segment.

### Config (`~/Library/Application Support/intuos3d/config.json`, created with defaults on first run)

```json
{
  "expressKeys": ["shift", "option", "cmd", "space", "cmd+z", "cmd+shift+z", "[", "]"],
  "leftStrip":   ["scroll:-1", "scroll:1"],
  "rightStrip":  ["cmd+=", "cmd+-"],
  "mapping": "fit",
  "penButton1": "right",
  "penButton2": "middle",
  "pressureGamma": 1,
  "logReports": false
}
```

Actions are key chords from `cmd`, `shift`, `option`, `ctrl` plus one key name (US layout: letters, digits,
`[ ] ; ' , . / \ - =`, `space`, `tab`, `return`, `escape`, `delete`, arrows, `f1`..`f20`, `home`, `end`,
`pageup`, `pagedown`), a lone modifier, `scroll:N`, or `none`. Edit, then `launchctl kickstart -k gui/$UID/local.intuos3d`.

### Install / permissions

```bash
cd intuos3d && ./install.sh
```

This builds, copies the binary to `~/Library/Application Support/intuos3d/intuos3d`, ad-hoc signs it with a fixed
identifier, writes `~/Library/LaunchAgents/local.intuos3d.plist` and bootstraps it (KeepAlive, logs to
`~/Library/Logs/intuos3d.log`). On first start macOS shows two prompts, both attributed to `intuos3d`:

1. **Input Monitoring**: required to open any mouse-class HID device with IOHIDManager. Without it
   `IOHIDManagerOpen` returns `0xe00002e2` (kIOReturnNotPermitted), which is exactly what the log shows right now.
   The driver polls `IOHIDCheckAccess` and restarts itself once this is granted.
2. **Accessibility**: required for `CGEventPost` to the HID event tap. Takes effect immediately.

`./uninstall.sh` removes everything; unplug/replug the tablet to return it to boot-mouse mode.

### Signing (why the first grants did not stick)

TCC identifies an ad-hoc signed binary by its code hash, so the grants made against the first build stopped
matching after the next `./install.sh`. The installer therefore signs with a self-signed code-signing certificate
named `intuos3d local code signing` when it finds one in the login keychain; the designated requirement becomes
`identifier "local.intuos3d" and certificate leaf = H"..."`, which is stable across rebuilds. The certificate was
created with `openssl req -x509` (`extendedKeyUsage = codeSigning`) and imported with
`security import ... -T /usr/bin/codesign`; it does not need to be trusted for this to work. Without it the
installer falls back to ad-hoc signing and warns. Stale `intuos3d` rows in Privacy & Security must be removed
(select, minus) before the re-signed binary can prompt again.

### Verification status

Verified with the real tablet on 2026-10-17 (log excerpts: `notes/first-session.log`):

* Permissions: after granting Input Monitoring the driver restarted itself; `IOHIDManagerOpen` succeeded and the
  mode switch read back `02 02` (`-> Intuos mode`). Grants survived later rebuilds thanks to the local certificate.
* Pen (Grip Pen, tool id `0x823`, eraser end `0x82b`, same serial): 3183 pen packets, x 1413..33423,
  y 5455..20293, distance 8..55, **pressure 0..1023 (full range)**, **tiltX -62..63, tiltY -64..63**, lower side
  button seen as `d[1] & 2`. Proximity enter/exit pairs matched (13/13). No unparsed pen reports.
* Apps: pressure strokes painted in Tayasui Sketches (which did not treat the eraser end as an eraser; the
  proximity event is now also posted as a mouse event with the TabletProximity subtype for apps that only read
  that form).
* ExpressKeys: all 8 report as single bits in `d[5]` (left block) and `d[6]` (right block). Pressed in the user's
  reading order, the left block produced bits 2, 0, 1, 3 and the right block 4, 5, 6, 7, so `expressKeys[i]` is
  "bit i", not necessarily "i-th key from the top"; swap entries in the config to match the physical layout.
* Strips: a one-hot 13-bit mask, **segment 1 at the top, 13 at the bottom**, moving one segment per report during
  a swipe. A resting hand produced a 4↔1 flicker on the right strip; jumps of more than two segments are ignored.

* Krita 5.3 Tablet Tester: strokes arrive as `Stylus press/move/release` with pressure, tilt in degrees and
  `(DRAW)`; the two side buttons arrive as `B=2` (right) and `B=4` (middle) presses, so the upper rocker
  (`d[1] & 4`) works too; proximity prints `Pen tip brought near` / `Eraser taken away`, i.e. Krita sees the
  pointer type. ("Stylus" in the tester is the device class, not the pointer type.)
* AppKit level (`tools/eventmon.swift`, log in `notes/appkit-eventmon.log`): proximity events decode as
  `pointingDeviceType` 1 for the pen (vendor tool 0x823) and 3 for the eraser end (0x82b), in both event forms;
  point events carry pressure and tilt with the matching `deviceID`.

Krita only uses an eraser brush for the eraser end after you pick one while the eraser end is active; it then
remembers the preset per pointer type. Tayasui Sketches did not treat the eraser end specially even though the
events are correct; that is an app limitation.

Not yet verified: airbrush/marker packets and the 2D mouse (no such tools at hand).

To log raw reports: set `"logReports": true` in the config and `launchctl kickstart -k gui/$UID/local.intuos3d`;
every HID report and parsed event goes to `~/Library/Logs/intuos3d.log`.

### Known limitations

* Main display only; no per-app mappings; no pressure curve beyond a gamma exponent.
* Whether "scroll:-1" on a downward strip swipe scrolls the way you expect depends on your scrolling
  preference; swap the two strip entries if not.
* Airbrush wheel, marker rotation and the 4D mouse are parsed as plain pen/mouse packets or ignored.
* `expressKeys[i]` is HID bit i; on this unit the left block's bits are not in top-to-bottom order.
* The tablet stays in Intuos mode after the driver exits (macOS then sees no cursor movement from it) until replug.

## License

MIT, see `LICENSE`.
