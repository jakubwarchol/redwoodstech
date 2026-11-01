# RedwoodsTech

One macOS menu bar app (a pine tree) that replaces the separate Awake and Mousefix apps and adds display layout presets.

- **Left-click** the tree to keep the Mac awake (display and idle sleep blocked). Filled tree = awake, outline = normal sleep. Always starts off; closing the lid still sleeps.
- **Right-click** (or control-click) for the menu: Keep Awake, Lock Keyboard for Cleaning, connected mice, display layouts, Open at Login, Quit.
- Registers itself as a login item on first launch and asks for Accessibility access (needed to reverse the scroll wheel).

## External mice

For every external mouse (built-in trackpad and Magic Trackpads are left alone):

- **Pointer acceleration off**, applied when it connects and again after wake. Sets `HIDUseLinearScalingMouseAcceleration = 1` through an `IOHIDEventSystemClient`, re-applied after 1 s and 3 s because macOS applies its own saved settings to a new device.
- **Scroll wheel reversed** (both axes) through a `CGEvent` tap, so the trackpad keeps natural scrolling. Events are matched to devices by HID sender ID; unknown senders fall back to "line-based events come from a wheel".

Same techniques as [LinearMouse](https://github.com/linearmouse/linearmouse) (MIT). The private IOKit declarations in `Sources/Bridging.h` come from LinearMouse's `IOKitSPIMac.h` (Apple BSD-style license).

## Keyboard cleaning

Right-click the tree → **Lock Keyboard for Cleaning**. The tree turns into a keyboard icon and every key is ignored (letters, modifiers, Fn, media/volume/brightness keys) while the mouse and trackpad keep working. Click the keyboard icon to unlock.

It unlocks on its own after 5 minutes, and whenever the Mac sleeps, the screen locks or you switch users, so you can always type your password. The power / Touch ID key can't be blocked; wipe around it. Uses an HID-level `CGEvent` tap that drops key events, the same technique as [Cleeb](https://github.com/eliseomartelli/Cleeb) and [keyboard-cleaner](https://github.com/gltchitm/keyboard-cleaner) (both MIT).

## Display layouts

A **setup** is the set of connected displays (identified by their hardware UUID, which survives reconnects) plus whether any external mouse is connected. Each setup can have one saved layout:

1. Arrange the displays in System Settings → Displays the way you want for the current setup (e.g. with the mouse plugged in for gaming).
2. Right-click the tree → **Save Layout for This Setup**.

Whenever the setup changes (mouse plugged in or out, monitor connected or disconnected) the saved layout for the new setup is applied: display positions, which one is main, and each display's resolution/refresh rate. It waits 2 s for things to settle and checks again 3 s later, because macOS restores its own remembered arrangement right after a display connects. Rearranging within the same setup is never undone, so you can tweak and re-save. Setups without a saved layout are left alone. **Switch Layouts Automatically** turns the auto-switching off; **Saved Layouts** lists and deletes presets.

Not covered: rotation and mirroring (private APIs), and telling different mice apart (any external mouse counts as "mouse connected"). Presets live in the app's user defaults (`tech.redwoods.redwoodstech`, key `displayPresets`).

## Build & install

```bash
./build.sh
```

Needs Xcode or the Command Line Tools. Builds `build/RedwoodsTech.app`, signs it with the "Apple Development" identity (override with `CODESIGN_IDENTITY=...`) so the Accessibility grant survives rebuilds, installs it to `/Applications` and launches it. For logs, quit the app and run `/Applications/RedwoodsTech.app/Contents/MacOS/RedwoodsTech` in a terminal.

## Icon credits

Pine tree (menu bar and app icon): [Phosphor Icons](https://phosphoricons.com) `tree-evergreen` bold/fill, MIT License.
