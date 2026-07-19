# 🎮 Arch Deckify — COSMIC / NVIDIA edition

A streamlined fork of [unlbslk/arch-deckify](https://github.com/unlbslk/arch-deckify)
that sets up a SteamOS-style **gamescope gaming session** on Arch Linux under
SDDM, tuned for machines where a *live* desktop → gaming handoff doesn't work —
most notably **NVIDIA laptops running COSMIC**.

It installs a Gaming Mode (gamescope) and wires up session switching to and from
your normal desktop, with a one-click "Return to Gaming Mode" shortcut.

---

## Why this fork exists

On an NVIDIA + COSMIC setup, upstream's live session handoff (log the desktop
out, let SDDM autologin relogin into gamescope) **black-screens**: COSMIC doesn't
release the NVIDIA DRM master cleanly, so gamescope autologins onto a dead
display — the Steam startup chime plays, but nothing renders. This edition
changes the behaviour and fixes a few sharp edges:

- **Reboot-based gaming switch.** Entering gaming mode sets the SDDM session and
  **reboots**, so the GPU is fully reset and SDDM autologin brings gamescope up
  clean. This is the only reliable desktop → gaming path on NVIDIA + COSMIC.
  Returning to the desktop stays instant (`steam -shutdown`, no reboot).
  Prefer the classic behaviour? Set `SWITCH_METHOD="live"` in
  `/usr/bin/steamos-session-select`.
- **Forced-AUR gamescope-session.** `gamescope-session-steam-git` is installed
  with the `aur/` prefix and the CachyOS `gamescope-session-cachyos` provider is
  removed first, so it can't hijack the package or the `gamescope-session`
  dependency.
- **Icon that COSMIC actually shows.** The gaming-mode icon is installed into
  the `hicolor` icon theme and referenced by name, not by absolute path.
- **Bug fix.** Upstream wrote the desktop session name into the switcher
  literally (`$selected_de`) instead of expanding it; this edition bakes the
  real value in.
- **Leaner.** The Deckify Helper, Decky Loader, and `system_update.sh` extras
  are dropped to keep the installer focused. Uninstall is built in.

---

## Requirements

- Arch Linux (or an Arch-based distro)
- **SDDM** as the display manager (the installer can install it for you)
- A Wayland desktop session to return to (COSMIC, KDE, GNOME, etc.)
- An AUR helper (`yay`/`paru`) — installed automatically if missing

---

## Install

Review the script first, then run it **without sudo**:

```bash
bash install.sh
```

You'll be asked which desktop session to return to, and prompted before the
CachyOS gamescope provider (if any) is removed. When it finishes, **reboot once**
— you'll land in your desktop.

---

## Using it

**Desktop → Gaming:** click **Return to Gaming Mode** (desktop icon / app menu),
or run:

```bash
steamos-session-select gamescope   # sets the session and reboots into gamescope
```

**Gaming → Desktop:** use Steam's built-in *Switch to Desktop* (Power menu), or:

```bash
steamos-session-select desktop     # returns to your chosen desktop, no reboot
```

### Change the default desktop later

The desktop session is baked into the switcher at install time. To change it,
just re-run the installer and pick a different session — simplest and safest.

> Don't use upstream's `change_default_desktop.sh` or the Deckify Helper's
> "Change Default Desktop" here: both rewrite `steamos-session-select` with the
> old **live handoff**, which would re-break desktop → gaming on NVIDIA + COSMIC.

---

## Uninstall

```bash
bash uninstall.sh
```

Prompts for confirmation, then removes `gamescope-session-steam-git`, the
switcher, the sudoers rule, the shortcut and icon, and disables SDDM autologin
(backing the config up to `/etc/sddm.conf.deckify.bak` first). It leaves general
packages (Steam, gamescope, mangohud, etc.) alone, and offers to delete the
`~/arch-deckify` folder. Reboot afterward for a normal SDDM greeter.

---

## Notes & gotchas

- **Blank icon on COSMIC?** COSMIC caches desktop icons — log out/in once (or
  toggle *Allow Launching* on the desktop icon) after installing.
- **The reboot is intentional.** It's not laziness — a live compositor handoff
  to gamescope doesn't work reliably on NVIDIA + COSMIC because the GPU/DRM
  master isn't released cleanly. A reboot is the dependable reset.
- **On a clean-handoff setup** (many AMD/Intel + KDE configs) you can switch to
  the instant path with `SWITCH_METHOD="live"` in the switcher.

---

## Credits

Built on [unlbslk/arch-deckify](https://github.com/unlbslk/arch-deckify) and the
[ChimeraOS gamescope-session-steam](https://github.com/ChimeraOS/gamescope-session-steam)
project. All Steam / SteamOS / Steam Deck / Valve names and logos belong to their
respective owners; this project is not affiliated with or endorsed by any of them.

> ⚠️ This script edits SDDM config, sudoers, system packages, and udev rules.
> It can leave a system unbootable to its GUI if something goes wrong. Back up
> first and use at your own risk.
