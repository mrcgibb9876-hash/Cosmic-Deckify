#!/bin/bash
#
# Arch Deckify — COSMIC / NVIDIA edition
# ===========================================================================
# A streamlined fork of unlbslk/arch-deckify that sets up a SteamOS-style
# gamescope gaming session on Arch under SDDM, tuned for machines where a
# LIVE desktop->gaming handoff doesn't work (notably NVIDIA + COSMIC).
#
# What differs from upstream:
#   * Gaming switch REBOOTS into the gamescope session instead of doing a live
#     compositor handoff. On NVIDIA + COSMIC the live handoff black-screens
#     (COSMIC doesn't release the DRM master, so gamescope autologins onto a
#     dead display — Steam chime plays, nothing renders). A reboot fully resets
#     the GPU and SDDM autologin brings gamescope up clean. Toggle in the
#     switcher via SWITCH_METHOD=live if you're on a setup that hands off fine.
#   * gamescope-session-steam-git is FORCED from the AUR (aur/ prefix) and the
#     CachyOS gamescope-session-cachyos provider is removed first, so it can't
#     hijack the package or the gamescope-session dependency.
#   * The gaming-mode icon is installed into the hicolor icon theme and
#     referenced by NAME, so COSMIC actually renders it.
#   * Fixes a latent upstream bug where the desktop session name was written
#     into the switcher literally ($selected_de) instead of expanded.
#   * Drops the Deckify Helper / Decky Loader / system_update extras to keep
#     the installer focused. Removal is handled by the separate uninstall.sh.
#
# Credits: unlbslk/arch-deckify and the ChimeraOS gamescope-session-steam team.
# Use at your own risk — it edits SDDM config, sudoers, and system packages.
# ===========================================================================

set -uo pipefail

SWITCHER="/usr/bin/steamos-session-select"
SDDM_CONF="/etc/sddm.conf"
SUDOERS_FILE="/etc/sudoers.d/sddm_config_edit"
ICON_NAME="steam-gaming-return"
ICON_URL="https://raw.githubusercontent.com/unlbslk/arch-deckify/refs/heads/main/icons/${ICON_NAME}.png"
GAMING_SESSION="gamescope-session-steam"
SHORTCUT="Return_to_Gaming_Mode.desktop"

c_info() { echo -e "\n\e[36m[*]\e[0m $1"; }
c_ok()   { echo -e "\e[32m[ok]\e[0m $1"; }
c_warn() { echo -e "\e[33m[!]\e[0m $1"; }
c_err()  { echo -e "\e[31m[x]\e[0m $1" >&2; }

if [ "$EUID" -eq 0 ]; then
    c_err "Run this WITHOUT root/sudo — it will sudo where needed."
    exit 1
fi

echo -e "\n\e[1;33mArch Deckify — COSMIC / NVIDIA edition\e[0m"
echo -e "\e[1;30m(To remove everything later, run: bash uninstall.sh)\e[0m"

# ---------------------------------------------------------------------------
# Preflight: SDDM must be the display manager
# ---------------------------------------------------------------------------
dm=$(basename "$(readlink /etc/systemd/system/display-manager.service 2>/dev/null)" 2>/dev/null)
if [ "$dm" != "sddm.service" ]; then
    c_err "SDDM is not the active display manager."
    read -rp "Install and enable SDDM now? (y/n): " a
    if [[ "$a" =~ ^[Yy]$ ]]; then
        pacman -Qi sddm &>/dev/null || sudo pacman -S sddm --noconfirm
        pacman -Qi sddm &>/dev/null || { c_err "SDDM install failed."; exit 1; }
        sudo systemctl disable display-manager.service 2>/dev/null || true
        sudo systemctl enable sddm.service
        c_ok "SDDM enabled."
    else
        exit 1
    fi
fi

sudo -v   # prime sudo

# ---------------------------------------------------------------------------
# Choose the desktop session to return to
# ---------------------------------------------------------------------------
available_desktops=$(ls /usr/share/wayland-sessions/*.desktop 2>/dev/null \
    | sed 's|/usr/share/wayland-sessions/||; s/\.desktop$//' | grep -v 'gamescope')

[ -n "$available_desktops" ] || { c_err "No non-gamescope Wayland session found for desktop mode."; exit 1; }

while true; do
    echo -e "\n\e[95mWayland desktop sessions found:\e[0m"
    echo "$available_desktops"
    echo -e "\n\e[95mWhich should be used when switching Steam -> desktop?\e[0m"
    read -rp "Session name: " selected_de
    if echo "$available_desktops" | grep -qw "^$selected_de"; then
        c_ok "'$selected_de' selected."
        break
    fi
    c_warn "No session named '$selected_de'."
done

# ---------------------------------------------------------------------------
# 1. AUR helper
# ---------------------------------------------------------------------------
c_info "[1/13] Checking for an AUR helper..."
if command -v yay &>/dev/null; then c_ok "yay present."
elif command -v paru &>/dev/null; then c_ok "paru present."
else
    c_info "Installing yay..."
    sudo pacman -S --needed base-devel git --noconfirm
    tmp=$(mktemp -d); git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    ( cd "$tmp/yay" && makepkg -si --noconfirm )
    command -v yay &>/dev/null || { c_err "yay install failed."; exit 1; }
    c_ok "yay installed."
fi

# ---------------------------------------------------------------------------
# 2. multilib
# ---------------------------------------------------------------------------
c_info "[2/13] Ensuring multilib is enabled..."
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
    c_ok "multilib enabled."
else
    c_ok "multilib already enabled."
fi

# ---------------------------------------------------------------------------
# 3. system update
# ---------------------------------------------------------------------------
c_info "[3/13] Updating the system..."
sudo pacman -Syu --noconfirm

# ---------------------------------------------------------------------------
# 4. Steam
# ---------------------------------------------------------------------------
c_info "[4/13] Ensuring Steam is installed..."
command -v steam &>/dev/null && c_ok "Steam present." || sudo pacman -S steam --noconfirm

# ---------------------------------------------------------------------------
# 5. gamescope-session-steam-git (FORCED from AUR; remove CachyOS provider)
# ---------------------------------------------------------------------------
c_info "[5/13] Installing gamescope-session-steam-git (forced AUR)..."

# The CachyOS 'gamescope-session-cachyos' package provides gamescope-session
# and will hijack either the package name or the dependency. Remove it first.
if pacman -Qq 2>/dev/null | grep -q '^gamescope-session-cachyos$'; then
    c_warn "CachyOS gamescope-session-cachyos found — it conflicts and must go."
    c_warn "(Reinstall later with: sudo pacman -S gamescope-session-cachyos)"
    read -rp "Remove it to continue? (y/n): " a
    [[ "$a" =~ ^[Yy]$ ]] || { c_err "Cancelled."; exit 1; }
    pacman -Qq | grep '^gamescope-session' | grep -v 'steam' | xargs -r sudo pacman -R --noconfirm
    sudo rm -f /usr/share/wayland-sessions/gamescope-session.desktop \
               /etc/sddm.conf.d/zz-steamos-autologin.conf
fi

# aur/ prefix forces the AUR package over any same-named/binary provider.
yay -S --noconfirm --sudoloop aur/gamescope-session-steam-git \
  || paru -S --noconfirm aur/gamescope-session-steam-git

if ! pacman -Qq 2>/dev/null | grep -q '^gamescope-session-steam-git$'; then
    c_err "gamescope-session-steam-git did not install. Check for AUR conflicts and re-run."
    exit 1
fi
c_ok "gamescope-session-steam-git installed from AUR."

# ---------------------------------------------------------------------------
# 6. SDDM autologin
# ---------------------------------------------------------------------------
c_info "[6/13] Configuring SDDM autologin..."
sudo tee "$SDDM_CONF" >/dev/null <<EOF
[Autologin]
Relogin=true
Session=$selected_de
User=$(whoami)

[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Theme]
Current=

[Users]
MaximumUid=60513
MinimumUid=1000
EOF
c_ok "Autologin set for $(whoami) (default session: $selected_de)."

# ---------------------------------------------------------------------------
# 7. steamos-session-select  (REBOOT-based gaming switch, desktop baked in)
# ---------------------------------------------------------------------------
c_info "[7/13] Writing $SWITCHER..."
# NOTE: $selected_de is expanded HERE (install time). Runtime vars are \$-escaped.
sudo tee "$SWITCHER" >/dev/null <<EOF
#!/usr/bin/bash
# Generated by Arch Deckify (COSMIC/NVIDIA edition).
CONFIG_FILE="$SDDM_CONF"
DESKTOP_SESSION="$selected_de"          # your desktop session (baked in at install)
GAMING_SESSION="$GAMING_SESSION"

# How to enter gaming mode from the desktop:
#   reboot : reset the GPU and autologin into gamescope (reliable on NVIDIA+COSMIC)
#   live   : classic in-place logout->relogin (fine where the GPU hands off cleanly)
SWITCH_METHOD="reboot"

if [ \$# -eq 0 ]; then
    echo "Valid arguments: plasma, gamescope"
    exit 0
fi

# Steam always calls "steamos-session-select plasma" to reach the desktop; we
# treat plasma/desktop the same and switch to \$DESKTOP_SESSION.
if [ "\$1" = "plasma" ] || [ "\$1" = "desktop" ]; then
    echo "Switching session to Desktop (\$DESKTOP_SESSION)."
    [ -f "\$CONFIG_FILE" ] || { echo "SDDM config not found at \$CONFIG_FILE"; exit 1; }
    sudo sed -i "s/^Session=.*/Session=\${DESKTOP_SESSION}/" "\$CONFIG_FILE"
    steam -shutdown

elif [ "\$1" = "gamescope" ]; then
    echo "Switching session to Gamescope."
    [ -f "\$CONFIG_FILE" ] || { echo "SDDM config not found at \$CONFIG_FILE"; exit 1; }
    sudo sed -i "s/^Session=.*/Session=\${GAMING_SESSION}/" "\$CONFIG_FILE"
    if [ "\$SWITCH_METHOD" = "live" ]; then
        niri msg action quit -s \\
          || dbus-send --session --type=method_call --print-reply --dest=org.kde.Shutdown /Shutdown org.kde.Shutdown.logout \\
          || gnome-session-quit --logout --no-prompt \\
          || cinnamon-session-quit --logout --no-prompt \\
          || loginctl terminate-session "\${XDG_SESSION_ID}"
    else
        systemctl reboot
    fi
else
    echo "Valid arguments are: plasma, gamescope."
    exit 1
fi
EOF
sudo chmod +x "$SWITCHER"
c_ok "Switcher written (gaming = reboot; desktop = $selected_de)."

# ---------------------------------------------------------------------------
# 8. sudoers rule (passwordless Session= edit; reboot itself needs no sudo)
# ---------------------------------------------------------------------------
c_info "[8/13] Adding sudoers rule for the Session= edit..."
if [ ! -f "$SUDOERS_FILE" ]; then
    echo "ALL ALL=(ALL) NOPASSWD: /usr/bin/sed -i s/^Session=*/Session=*/ ${SDDM_CONF}" \
        | sudo tee "$SUDOERS_FILE" >/dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    c_ok "sudoers rule added."
else
    c_ok "sudoers rule already present."
fi

# ---------------------------------------------------------------------------
# 9. supporting packages
# ---------------------------------------------------------------------------
c_info "[9/13] Installing supporting packages (mangohud, ntfs-3g, gamescope)..."
for pkg in mangohud ntfs-3g gamescope wget; do
    pacman -Qs "$pkg" >/dev/null || sudo pacman -S "$pkg" --noconfirm
done
c_ok "Supporting packages present."

# ---------------------------------------------------------------------------
# 10. backlight rule (brightness control from Steam on handhelds/laptops)
# ---------------------------------------------------------------------------
c_info "[10/13] Adding backlight udev rule..."
sudo usermod -aG video "$(whoami)"
if ! grep -qs 'SUBSYSTEM=="backlight"' /etc/udev/rules.d/backlight.rules 2>/dev/null; then
    echo 'ACTION=="add", SUBSYSTEM=="backlight", RUN+="/bin/chgrp video $sys$devpath/brightness", RUN+="/bin/chmod g+w $sys$devpath/brightness"' \
        | sudo tee -a /etc/udev/rules.d/backlight.rules >/dev/null
fi
c_ok "Backlight rule in place."

# ---------------------------------------------------------------------------
# 11. themed icon (so COSMIC renders it)
# ---------------------------------------------------------------------------
c_info "[11/13] Installing gaming-mode icon into the hicolor theme..."
mkdir -p "$HOME/arch-deckify"
if [ ! -f "$HOME/arch-deckify/${ICON_NAME}.png" ]; then
    wget -qO "$HOME/arch-deckify/${ICON_NAME}.png" "$ICON_URL" \
        || c_warn "Icon download failed; shortcut will fall back to a generic icon."
fi
if [ -f "$HOME/arch-deckify/${ICON_NAME}.png" ]; then
    install -Dm644 "$HOME/arch-deckify/${ICON_NAME}.png" \
        "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png"
    command -v gtk-update-icon-cache >/dev/null \
        && gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    c_ok "Icon installed as themed name '$ICON_NAME'."
fi

# ---------------------------------------------------------------------------
# 12. Return to Gaming Mode shortcut (desktop + user application menu)
# ---------------------------------------------------------------------------
c_info "[12/13] Creating 'Return to Gaming Mode' shortcut..."
ENTRY="[Desktop Entry]
Type=Application
Name=Return to Gaming Mode
Comment=Reboot into the Steam gamescope gaming session
Exec=steamos-session-select gamescope
Icon=${ICON_NAME}
Terminal=false
Categories=Game;
StartupNotify=false"

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
mkdir -p "$DESKTOP_DIR" "$HOME/.local/share/applications"
printf '%s\n' "$ENTRY" > "$DESKTOP_DIR/$SHORTCUT"
printf '%s\n' "$ENTRY" > "$HOME/.local/share/applications/$SHORTCUT"
chmod +x "$DESKTOP_DIR/$SHORTCUT" "$HOME/.local/share/applications/$SHORTCUT"
command -v update-desktop-database >/dev/null \
    && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
c_ok "Shortcut created on desktop and in the app menu."

# ---------------------------------------------------------------------------
# 13. Bluetooth
# ---------------------------------------------------------------------------
c_info "[13/13] Enabling Bluetooth..."
sudo pacman -S bluez bluez-utils --noconfirm
sudo systemctl enable --now bluetooth.service
c_ok "Bluetooth enabled."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo -e "\n\e[1;33mInstallation complete.\e[0m\n"
echo "  • Reboot once now; you'll land in your desktop ($selected_de)."
echo "  • Click 'Return to Gaming Mode' to reboot straight into gamescope."
echo "  • From gaming mode, Steam's 'Switch to Desktop' returns you to $selected_de (live, no reboot)."
echo "  • COSMIC caches desktop icons — if the icon looks blank, log out/in once."
echo "  • Prefer the classic live handoff? Set SWITCH_METHOD=\"live\" in $SWITCHER."
echo "  • Uninstall anytime:  bash uninstall.sh"
