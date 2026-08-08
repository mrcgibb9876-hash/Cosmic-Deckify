# 🎮 Cosmic Deckify

Turns an Arch Linux + COSMIC desktop into a two-mode machine, Steam Deck
style: your regular desktop, and a full-screen **Gaming Mode** built around
Steam Big Picture.

## What it does

- Adds a **Gaming Mode** — a console-style, controller-friendly Steam Big
  Picture screen that takes over the whole display. No desktop, taskbar, or
  windows in the way, just your games.
- Lets you jump between your COSMIC desktop and Gaming Mode instantly with a
  hotkey, in either direction, with no reboot required.
- Adds a "Return to Gaming Mode" desktop shortcut as a mouse-driven
  alternative to the hotkey.
- Keeps itself working after system updates — if a package update changes
  how the gaming session starts, Cosmic Deckify quietly adjusts instead of
  breaking.

## Switching modes

- **Desktop → Gaming Mode:** press `Super + Shift + S`, or click the desktop
  shortcut
- **Gaming Mode → Desktop:** press `Super + Shift + R`, or use Steam's own
  "Switch to Desktop" option — both work even while Gaming Mode has full
  control of the screen

## Install

```bash
bash install.sh
```

Installs everything needed (Steam, gamescope, the hotkey daemon, [Proton
Command Center](https://github.com/mrcgibb9876-hash/proton_command_center)
for per-game launch options/DLSS/ReShade, and some Arch/COSMIC-specific
setup), then asks for a reboot once it's done. After that, you land straight
in your COSMIC desktop and both hotkeys are live.

Check what's currently set up at any time with:

```bash
bash install.sh --status
```

## Uninstall

```bash
bash uninstall.sh
```

Removes Gaming Mode, the hotkeys, and everything Cosmic Deckify added,
leaving your regular COSMIC desktop exactly as it was. Steam and your
graphics drivers are left in place.

## Notes

- Built for Arch Linux (or an Arch-based distro) running COSMIC as the
  desktop.
- On NVIDIA graphics, mode switches happen via a quick, safe restart rather
  than an instant handoff, since NVIDIA doesn't always hand off cleanly
  between the two modes live. If a switch ever misbehaves, there's a
  slower-but-guaranteed fallback described inside the script.
- Occasionally the "back to desktop" hotkey doesn't fire while Gaming Mode
  has the screen — Steam's own "Switch to Desktop" button always works as a
  backup.
- If the hotkeys ever stop working entirely, just re-run `bash install.sh` —
  it's safe to run again and will repair anything that's drifted.

## Credits

Built on the [ChimeraOS gamescope-session](https://github.com/ChimeraOS/gamescope-session-steam)
project and [triggerhappy](https://github.com/wertarbyte/triggerhappy). Steam,
SteamOS, and Steam Deck names/logos belong to Valve; this project isn't
affiliated with or endorsed by them.

> ⚠️ This script edits system configuration (greetd, sudoers, kernel modules)
> and installs packages. Back up first and use at your own risk.
