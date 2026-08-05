# 🎮 Cosmic Deckify

Turns a vanilla Arch + COSMIC install into a SteamOS-style two-mode machine:
**COSMIC desktop** and **gamescope Gaming Mode (Steam Big Picture)**, switched
with **Super+Shift+S** (desktop → gaming) and **Super+Shift+R** (gaming →
desktop) — no reboot required to get back, and the hotkeys work no matter
which of the two sessions currently owns the screen.

---

## How it actually works

This isn't a reboot-and-a-desktop-icon script. Three things had to be true at
once, and each was verified against the real packages (not assumed):

- **greetd, not SDDM.** Vanilla Arch + COSMIC boots via `greetd` +
  `cosmic-greeter`. greetd's `default_session` is normally "the greeter," but
  per `greetd(1)`/`greetd(5)`, pointing it straight at a real session command
  *is* its auto-login mechanism: "the default session ... started again
  whenever no session is running, such as when the user logs out." greetd's
  source confirms `config.toml` is read exactly once at daemon startup (no
  reload/SIGHUP support) — so switching sessions means editing the config
  **and** restarting `greetd.service`, not just logging out.
- **The gaming session's own switcher is left alone.**
  `gamescope-session-steam-git` (AUR) ships its own `/usr/bin/steamos-session-select`
  — a thin dispatcher that execs `/usr/lib/os-session-select` if present. This
  project writes *that* file instead of overwriting the package's own script,
  so a `pacman -Syu` upgrade of the AUR package can't silently revert your
  switching logic.
- **Super+Shift+R has to work from inside gamescope**, where COSMIC (and its
  keybinding system) isn't even running. [swhkd](https://github.com/waycrate/swhkd)
  reads keyboard input directly from `/dev/input`, underneath any Wayland
  compositor, so the hotkey works regardless of which session currently has
  the screen. It ships no systemd units upstream, so this project writes them.

## The one thing that can't be verified from a script

If you're on **NVIDIA**: its proprietary driver is widely reported to not
release DRM master cleanly to a second compositor on a live handoff. The
switch here uses `systemctl restart greetd` (which forcibly kills the whole
session's cgroup, rather than a polite compositor-side logout) as a
faster-than-reboot middle ground — but whether *your* specific driver/kernel
combination hands off cleanly through that isn't something any installer can
know in advance. If Super+Shift+S black-screens instead of switching, open:

```
/usr/local/bin/deckify-session-switch
```

and change `SWITCH_METHOD="restart"` to `SWITCH_METHOD="reboot"`. Slower, but
guaranteed to reset the GPU state fully.

On AMD/Intel this isn't expected to be an issue — their open-source KMS
drivers hand off DRM master between compositors as a matter of course.

---

## Requirements

- Arch Linux (or an Arch-based distro) with COSMIC already the target desktop
- An AUR helper (`yay`/`paru`) — installed automatically if missing
- Steam, gamescope, and the underlying VT/session-management this script sets up

## Install

Review the script first, then run it **without sudo**:

```bash
bash install.sh
```

It will:
1. Install COSMIC + greetd (if not already present), Steam + gamescope
2. Install `gamescope-session-git` + `gamescope-session-steam-git` and
   `swhkd-git` from the AUR
3. (NVIDIA only) set `nvidia_drm.modeset=1` and add early-KMS modules to
   `mkinitcpio.conf`, rebuilding the initramfs
4. Configure greetd to auto-launch COSMIC on login
5. Write the session-switch helper, the `os-session-select` hook, a narrowly
   scoped sudoers rule (two literal commands, no wildcards), and the swhkd
   hotkey config + systemd units
6. Add a "Return to Gaming Mode" desktop shortcut as a mouse-driven fallback

**Reboot once** when it finishes — needed regardless of GPU, since greetd is
only just taking over session management (and NVIDIA's initramfs change needs
it too).

## Using it

- **Desktop → Gaming:** press **Super+Shift+S**, or click the desktop shortcut
- **Gaming → Desktop:** press **Super+Shift+R**, or use Steam's own
  *Switch to Desktop* (Power menu) — both go through the same
  `steamos-session-select` path

## Uninstall

```bash
bash uninstall.sh
```

Removes swhkd/swhks, the `os-session-select` hook, the switch helper, the
sudoers rule, the desktop shortcut, and the `gamescope-session-*` AUR
packages — then resets greetd to its stock (non-autologin) config. Leaves
Steam, gamescope, COSMIC, and any NVIDIA driver packages installed and marked
explicit, so they aren't swept up as "unneeded dependencies."

---

## Credits

Built on the [ChimeraOS gamescope-session](https://github.com/ChimeraOS/gamescope-session-steam)
/ `OpenGamingCollective/gamescope-session-steam` project and
[waycrate/swhkd](https://github.com/waycrate/swhkd). All Steam / SteamOS /
Steam Deck / Valve names and logos belong to their respective owners; this
project is not affiliated with or endorsed by any of them.

> ⚠️ This script edits greetd config, sudoers, mkinitcpio/kernel modules, and
> system packages. Back up first and use at your own risk.
