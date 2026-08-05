#!/bin/bash
#
# Cosmic Deckify — vanilla Arch + COSMIC + gamescope, hotkey-switched
# ===========================================================================
# Sets up a SteamOS-style Gaming Mode (gamescope + Steam Big Picture) on a
# vanilla Arch install running COSMIC, and wires Super+Shift+S / Super+Shift+R
# as global hotkeys to switch between COSMIC and Gaming Mode.
#
# Architecture (verified against the real packages, not guessed):
#   * COSMIC on Arch boots via greetd + cosmic-greeter, NOT SDDM. greetd's
#     `default_session` is "the greeter" by convention, but nothing stops it
#     being pointed straight at a real session command — per greetd(1)/(5),
#     doing so IS its auto-login mechanism: "the default session ... started
#     again whenever no session is running, such as when the user logs out."
#     Confirmed against greetd's source: config.toml is parsed exactly once at
#     daemon startup (no SIGHUP/reload support), so switching sessions means
#     editing config.toml AND restarting greetd.service — not just logging out.
#   * gamescope-session-steam-git (AUR) ships its OWN /usr/bin/steamos-session-select,
#     which is a thin dispatcher: it execs /usr/lib/os-session-select (or
#     /usr/libexec/os-session-select) if present, else just runs `steam -shutdown`.
#     This script writes /usr/lib/os-session-select instead of clobbering the
#     package's own file — clobbering it would silently revert on the next
#     package update and fights pacman's file ownership.
#   * Super+Shift+R has to work from *inside* gamescope, where COSMIC (and its
#     keybinding system) isn't running. swhkd reads raw evdev directly, below
#     any Wayland compositor, so it keeps working no matter which session has
#     the screen. It ships no systemd units, so this script writes them.
#   * NVIDIA's proprietary driver is widely reported to not release the DRM
#     master cleanly to a second compositor on a live handoff. `systemctl
#     restart greetd` forcibly kills the whole session cgroup (not a polite
#     compositor-side logout), which is a better bet than a live handoff, but
#     is NOT guaranteed clean on every driver/kernel combo — this needs to be
#     verified on your actual hardware. A full-reboot fallback is one flag
#     away in the generated switch helper if the fast path black-screens.
#
# Run without sudo — it will sudo where needed.
# ===========================================================================

set -uo pipefail

GREETD_CONF="/etc/greetd/config.toml"
SWITCH_HELPER="/usr/local/bin/deckify-session-switch"
OS_SESSION_SELECT="/usr/lib/os-session-select"
SUDOERS_FILE="/etc/sudoers.d/deckify-session-switch"
SWHKD_CONF="/etc/swhkd/swhkdrc"
ICON_NAME="steam-gaming-return"
SHORTCUT="Return_to_Gaming_Mode.desktop"
COSMIC_CMD="/usr/bin/start-cosmic"
GAMESCOPE_CMD="gamescope-session-plus steam"
TARGET_USER="$(whoami)"

c_info() { echo -e "\n\e[36m[*]\e[0m $1"; }
c_ok()   { echo -e "\e[32m[ok]\e[0m $1"; }
c_warn() { echo -e "\e[33m[!]\e[0m $1"; }
c_err()  { echo -e "\e[31m[x]\e[0m $1" >&2; }

if [ "$EUID" -eq 0 ]; then
    c_err "Run this WITHOUT root/sudo — it will sudo where needed."
    exit 1
fi

command -v pacman &>/dev/null || { c_err "This installer is for Arch (or an Arch-based distro) only."; exit 1; }

echo -e "\n\e[1;33mCosmic Deckify — Arch + COSMIC + gamescope, hotkey-switched\e[0m"
echo -e "\e[1;30m(To remove everything later, run: bash uninstall.sh)\e[0m"

sudo -v

# ---------------------------------------------------------------------------
# GPU detection — only NVIDIA needs the modeset workaround / reboot fallback
# ---------------------------------------------------------------------------
IS_NVIDIA=0
if lspci -k 2>/dev/null | grep -qi 'nvidia'; then
    IS_NVIDIA=1
    c_warn "NVIDIA GPU detected. Live session switching is a known-fragile area on"
    c_warn "NVIDIA + Wayland (the driver doesn't always release DRM master cleanly"
    c_warn "to a second compositor). This installer sets up the fast path"
    c_warn "(systemctl restart greetd) by default, with a reboot fallback you can"
    c_warn "enable in $SWITCH_HELPER if it black-screens on your hardware."
fi

# ---------------------------------------------------------------------------
# 1. AUR helper
# ---------------------------------------------------------------------------
c_info "[1/13] Checking for an AUR helper..."
if command -v yay &>/dev/null; then c_ok "yay present."
elif command -v paru &>/dev/null; then c_ok "paru present."
else
    c_info "Installing yay..."
    sudo pacman -S --needed base-devel git --noconfirm
    tmp=$(mktemp -d); git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay"
    ( cd "$tmp/yay" && makepkg -si --noconfirm )
    command -v yay &>/dev/null || { c_err "yay install failed."; exit 1; }
    c_ok "yay installed."
fi
AUR_HELPER="$(command -v yay || command -v paru)"

# ---------------------------------------------------------------------------
# 2. multilib + system update
# ---------------------------------------------------------------------------
c_info "[2/13] Ensuring multilib is enabled..."
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
    c_ok "multilib enabled."
else
    c_ok "multilib already enabled."
fi
c_info "Updating the system..."
sudo pacman -Syu --noconfirm

# ---------------------------------------------------------------------------
# 3. COSMIC + greetd
# ---------------------------------------------------------------------------
c_info "[3/13] Installing COSMIC desktop + greetd..."
sudo pacman -S --needed --noconfirm cosmic greetd greetd-tuigreet
for pkg in cosmic-session cosmic-comp cosmic-greeter greetd; do
    pacman -Qq "$pkg" &>/dev/null || { c_err "$pkg failed to install — check the pacman output above (e.g. a file conflict) and re-run."; exit 1; }
done
c_ok "COSMIC + greetd installed."

# ---------------------------------------------------------------------------
# 4. Steam + gamescope
# ---------------------------------------------------------------------------
c_info "[4/13] Installing Steam + gamescope..."
sudo pacman -S --needed --noconfirm steam gamescope
for pkg in steam gamescope; do
    pacman -Qq "$pkg" &>/dev/null || { c_err "$pkg failed to install — check the pacman output above and re-run."; exit 1; }
done
c_ok "Steam + gamescope installed."

# ---------------------------------------------------------------------------
# 5. gamescope-session-steam-git (AUR)
# ---------------------------------------------------------------------------
c_info "[5/13] Installing gamescope-session-steam-git (AUR)..."
"$AUR_HELPER" -S --noconfirm --needed aur/gamescope-session-git aur/gamescope-session-steam-git
if ! pacman -Qq gamescope-session-steam-git &>/dev/null; then
    c_err "gamescope-session-steam-git did not install. Re-run after checking for AUR conflicts."
    exit 1
fi
c_ok "gamescope-session-steam-git installed."
[ -f /usr/share/wayland-sessions/gamescope-session-steam.desktop ] \
    || c_warn "Expected session file not found — the AUR package may have changed layout."

# ---------------------------------------------------------------------------
# 6. swhkd-git (AUR) — global hotkey daemon, works underneath any compositor
# ---------------------------------------------------------------------------
c_info "[6/13] Installing swhkd-git (AUR)..."
"$AUR_HELPER" -S --noconfirm --needed aur/swhkd-git
command -v swhkd &>/dev/null || { c_err "swhkd install failed."; exit 1; }
c_ok "swhkd installed."

sudo usermod -aG input "$TARGET_USER"
c_ok "$TARGET_USER added to 'input' group (needed for swhkd's raw evdev access)."

# ---------------------------------------------------------------------------
# 7. NVIDIA: nvidia_drm.modeset=1 + early KMS (only if NVIDIA present)
# ---------------------------------------------------------------------------
c_info "[7/13] NVIDIA modeset check..."
if [ "$IS_NVIDIA" -eq 1 ]; then
    if ! { pacman -Qq nvidia &>/dev/null || pacman -Qq nvidia-open &>/dev/null; }; then
        c_warn "No nvidia/nvidia-open driver package detected."
        read -rp "Install 'nvidia-open nvidia-utils' now? (y/n): " a
        [[ "$a" =~ ^[Yy]$ ]] && sudo pacman -S --needed --noconfirm nvidia-open nvidia-utils
    fi
    sudo mkdir -p /etc/modprobe.d
    if ! grep -qs 'modeset=1' /etc/modprobe.d/nvidia.conf 2>/dev/null; then
        echo 'options nvidia_drm modeset=1 fbdev=1' | sudo tee /etc/modprobe.d/nvidia.conf >/dev/null
        c_ok "Set nvidia_drm modeset=1 in /etc/modprobe.d/nvidia.conf."
    else
        c_ok "nvidia_drm modeset=1 already configured."
    fi
    if [ -f /etc/mkinitcpio.conf ] && ! grep -qE '^MODULES=.*nvidia_drm' /etc/mkinitcpio.conf; then
        sudo sed -i -E 's/^MODULES=\(([^)]*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
        sudo sed -i -E 's/MODULES=\( +/MODULES=(/' /etc/mkinitcpio.conf
        sudo mkinitcpio -P
        c_ok "Added early KMS nvidia modules to mkinitcpio and regenerated initramfs."
        c_warn "This specific change needs a REBOOT to take effect (unrelated to session switching)."
    fi
else
    c_ok "No NVIDIA GPU detected — skipping (your GPU's KMS driver handles this natively)."
fi

# ---------------------------------------------------------------------------
# 8. greetd config: perpetual autologin into COSMIC
# ---------------------------------------------------------------------------
c_info "[8/13] Configuring greetd autologin (COSMIC by default)..."
sudo tee "$GREETD_CONF" >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "$COSMIC_CMD"
user = "$TARGET_USER"
EOF
c_ok "greetd will auto-launch COSMIC for $TARGET_USER on VT1."

# ---------------------------------------------------------------------------
# 9. Root switch helper — the only thing sudoers grants NOPASSWD access to
# ---------------------------------------------------------------------------
c_info "[9/13] Writing $SWITCH_HELPER..."
sudo tee "$SWITCH_HELPER" >/dev/null <<EOF
#!/bin/bash
# Generated by Cosmic Deckify. Rewrites greetd's default_session and restarts
# greetd so it picks up the change (greetd only reads config.toml once at its
# own startup — see greetd(5) — so a plain logout is NOT enough).
set -euo pipefail

GREETD_CONF="$GREETD_CONF"
TARGET_USER="$TARGET_USER"
COSMIC_CMD="$COSMIC_CMD"
GAMESCOPE_CMD="$GAMESCOPE_CMD"

# Set to "reboot" here if a plain greetd restart doesn't cleanly hand off the
# GPU on your NVIDIA/kernel combination — costs time but resets the DRM state
# fully. Try the default first.
SWITCH_METHOD="restart"

case "\${1:-}" in
    gamescope)
        cmd="\$GAMESCOPE_CMD" ;;
    desktop)
        cmd="\$COSMIC_CMD" ;;
    *)
        echo "Usage: \$0 {gamescope|desktop}" >&2
        exit 1 ;;
esac

cat > "\$GREETD_CONF" <<INNER
[terminal]
vt = 1

[default_session]
command = "\$cmd"
user = "\$TARGET_USER"
INNER

if [ "\$SWITCH_METHOD" = "reboot" ]; then
    systemctl reboot
else
    systemctl restart greetd.service
fi
EOF
sudo chmod 755 "$SWITCH_HELPER"
sudo chown root:root "$SWITCH_HELPER"
c_ok "Switch helper written."

# ---------------------------------------------------------------------------
# 10. Self-healing pacman hook — if gamescope-session-steam-git/gamescope-
#     session-git ever change the Exec= line of the gamescope wayland
#     session (a rename, a new wrapper, etc.), GAMESCOPE_CMD baked into
#     $SWITCH_HELPER would silently go stale. This hook fires on every
#     install/upgrade of those two packages and re-derives it from whatever
#     .desktop file is actually installed, patching both the switch helper
#     and (if it's the one currently active) greetd's config.toml.
# ---------------------------------------------------------------------------
c_info "[10/14] Installing self-healing pacman hook for gamescope-session updates..."
SYNC_SCRIPT="/usr/local/bin/deckify-sync-gamescope-session"
sudo tee "$SYNC_SCRIPT" >/dev/null <<'EOF'
#!/bin/bash
# Generated by Cosmic Deckify. Run by a pacman hook whenever
# gamescope-session-steam-git / gamescope-session-git is installed/upgraded.
# Re-derives the gamescope session's Exec= line from whatever wayland-session
# file is actually installed, and patches it into deckify-session-switch (and
# greetd's config.toml, if that's the command currently active there) so an
# upstream change to the session command can't silently break the switch.
set -uo pipefail

SWITCH_HELPER="/usr/local/bin/deckify-session-switch"
GREETD_CONF="/etc/greetd/config.toml"

[ -f "$SWITCH_HELPER" ] || exit 0

session_file="$(grep -l '^DesktopNames=gamescope$' /usr/share/wayland-sessions/*.desktop 2>/dev/null | head -n1)"
if [ -z "$session_file" ]; then
    echo "deckify: no gamescope wayland-session file found — nothing to sync" >&2
    exit 0
fi

new_cmd="$(sed -n 's/^Exec=//p' "$session_file" | head -n1)"
if [ -z "$new_cmd" ]; then
    echo "deckify: couldn't read Exec= from $session_file — nothing to sync" >&2
    exit 0
fi

old_cmd="$(sed -n 's/^GAMESCOPE_CMD="\(.*\)"$/\1/p' "$SWITCH_HELPER")"
if [ "$new_cmd" = "$old_cmd" ]; then
    exit 0
fi

escape_repl() { printf '%s' "$1" | sed -e 's/[\&#]/\\&/g'; }
new_esc="$(escape_repl "$new_cmd")"
old_esc="$(escape_repl "$old_cmd")"

echo "deckify: gamescope session command changed on package update:" >&2
echo "  old: $old_cmd" >&2
echo "  new: $new_cmd" >&2

sed -i "s#^GAMESCOPE_CMD=\".*\"\$#GAMESCOPE_CMD=\"$new_esc\"#" "$SWITCH_HELPER"

if [ -f "$GREETD_CONF" ] && grep -qF "command = \"$old_cmd\"" "$GREETD_CONF"; then
    sed -i "s#command = \"$old_esc\"#command = \"$new_esc\"#" "$GREETD_CONF"
    echo "deckify: greetd.conf was pointing at the old command; patched it too." >&2
fi

echo "deckify: gamescope session command re-synced successfully." >&2
EOF
sudo chmod 755 "$SYNC_SCRIPT"
sudo chown root:root "$SYNC_SCRIPT"

sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/deckify-gamescope-session.hook >/dev/null <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = gamescope-session-steam-git
Target = gamescope-session-git

[Action]
Description = Cosmic Deckify: re-syncing gamescope session command...
When = PostTransaction
Exec = $SYNC_SCRIPT
EOF
c_ok "Self-healing pacman hook installed."

# ---------------------------------------------------------------------------
# 11. os-session-select hook — the AUR package's own steamos-session-select
#     dispatches here; we do NOT touch /usr/bin/steamos-session-select itself.
# ---------------------------------------------------------------------------
c_info "[11/14] Writing $OS_SESSION_SELECT..."
sudo mkdir -p "$(dirname "$OS_SESSION_SELECT")"
sudo tee "$OS_SESSION_SELECT" >/dev/null <<EOF
#!/bin/bash
# Generated by Cosmic Deckify.
# steamos-session-select (from gamescope-session-steam-git) execs this file
# with "plasma"|"desktop"|"gamescope" as \$1 — Steam's own UI always passes
# "plasma" for its "Switch to Desktop" action, regardless of your actual DE.
case "\${1:-}" in
    plasma|desktop)
        exec sudo -n "$SWITCH_HELPER" desktop ;;
    gamescope)
        exec sudo -n "$SWITCH_HELPER" gamescope ;;
    *)
        echo "Valid arguments: desktop, gamescope" >&2
        exit 1 ;;
esac
EOF
sudo chmod 755 "$OS_SESSION_SELECT"
c_ok "os-session-select hook installed."

# ---------------------------------------------------------------------------
# 12. sudoers — two literal commands only, no wildcards
# ---------------------------------------------------------------------------
c_info "[12/14] Adding sudoers rule..."
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<EOF
$TARGET_USER ALL=(root) NOPASSWD: $SWITCH_HELPER gamescope
$TARGET_USER ALL=(root) NOPASSWD: $SWITCH_HELPER desktop
EOF
if sudo visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
    sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    c_ok "sudoers rule installed."
else
    c_err "Generated sudoers file failed validation — not installed. Session switching will prompt for a password."
fi
rm -f "$SUDOERS_TMP"

# ---------------------------------------------------------------------------
# 13. swhkd: hotkeys + systemd units (none are shipped by the AUR package)
# ---------------------------------------------------------------------------
c_info "[13/14] Configuring Super+Shift+S / Super+Shift+R hotkeys..."
sudo mkdir -p "$(dirname "$SWHKD_CONF")"
sudo tee "$SWHKD_CONF" >/dev/null <<'EOF'
# Generated by Cosmic Deckify.
# Desktop (COSMIC) -> Gaming Mode
super + shift + s
	steamos-session-select gamescope

# Gaming Mode -> Desktop (works from inside gamescope: swhkd grabs evdev
# directly, independent of whichever compositor currently owns the screen)
super + shift + r
	steamos-session-select desktop
EOF

sudo tee /etc/systemd/system/swhkd.service >/dev/null <<'EOF'
[Unit]
Description=Simple Wayland HotKey Daemon
After=local-fs.target

[Service]
ExecStart=/usr/bin/swhkd
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$HOME/.config/systemd/user"
tee "$HOME/.config/systemd/user/swhks.service" >/dev/null <<'EOF'
[Unit]
Description=swhkd IPC server (environment sourcing for swhkd)

[Service]
ExecStart=/usr/bin/swhks
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now swhkd.service
sudo loginctl enable-linger "$TARGET_USER"
systemctl --user daemon-reload
systemctl --user enable --now swhks.service

if systemctl is-active --quiet swhkd.service && systemctl --user is-active --quiet swhks.service; then
    c_ok "Hotkeys active: Super+Shift+S (desktop->gaming), Super+Shift+R (gaming->desktop)."
else
    c_warn "swhkd/swhks did not report as active — hotkeys may not work until you check:"
    c_warn "  systemctl status swhkd.service ; systemctl --user status swhks.service"
fi

# ---------------------------------------------------------------------------
# 14. Desktop shortcut (mouse-driven fallback alongside the hotkey)
# ---------------------------------------------------------------------------
c_info "[14/14] Creating 'Return to Gaming Mode' shortcut..."
ICON_URL="https://raw.githubusercontent.com/unlbslk/arch-deckify/refs/heads/main/icons/${ICON_NAME}.png"
mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps" "$HOME/.local/share/applications"
if [ ! -f "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png" ]; then
    wget -qO "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png" "$ICON_URL" \
        || c_warn "Icon download failed; shortcut will fall back to a generic icon."
fi
ENTRY="[Desktop Entry]
Type=Application
Name=Return to Gaming Mode
Comment=Switch to the Steam gamescope gaming session
Exec=steamos-session-select gamescope
Icon=${ICON_NAME}
Terminal=false
Categories=Game;
StartupNotify=false"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$DESKTOP_DIR"
printf '%s\n' "$ENTRY" > "$DESKTOP_DIR/$SHORTCUT"
printf '%s\n' "$ENTRY" > "$HOME/.local/share/applications/$SHORTCUT"
chmod +x "$DESKTOP_DIR/$SHORTCUT" "$HOME/.local/share/applications/$SHORTCUT"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
c_ok "Shortcut created."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo -e "\n\e[1;33mInstallation complete.\e[0m\n"
echo "  • Reboot once now (needed either way: greetd is only just starting to"
echo "    manage your session, and NVIDIA's initramfs change needs it too)."
echo "  • You'll land in COSMIC automatically."
echo "  • Super+Shift+S switches to Gaming Mode (Steam Big Picture / gamescope)."
echo "  • Super+Shift+R switches back to COSMIC — works even while gamescope"
echo "    has the screen, since swhkd reads raw input independent of it."
echo "  • Steam's own 'Switch to Desktop' button does the same as Super+Shift+R."
if [ "$IS_NVIDIA" -eq 1 ]; then
    echo -e "\n  \e[33mNVIDIA note:\e[0m the switch defaults to a fast 'systemctl restart"
    echo "  greetd' rather than a live handoff, because NVIDIA doesn't reliably"
    echo "  release DRM master to a second compositor in place. This has NOT been"
    echo "  verified on your specific driver/kernel combination — if the screen"
    echo "  goes black instead of switching, edit SWITCH_METHOD in:"
    echo "    $SWITCH_HELPER"
    echo "  and set it to \"reboot\" for a guaranteed-clean (but slower) switch."
fi
echo -e "\n  • Uninstall anytime:  bash uninstall.sh"
