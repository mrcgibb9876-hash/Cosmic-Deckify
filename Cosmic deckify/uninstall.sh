#!/bin/bash
#
# uninstall.sh — Cosmic Deckify
# ---------------------------------------------------------------------------
# Reverses install.sh: removes the swhkd hotkey daemon + units, the
# os-session-select hook, the switch helper, the sudoers rule, the shortcut +
# icon, and resets greetd back to its stock greeter config (no more autologin).
#
# It does NOT remove general packages you may want to keep (Steam, gamescope,
# COSMIC itself, nvidia drivers) — only the Deckify-specific glue.
# ---------------------------------------------------------------------------

set -uo pipefail

GREETD_CONF="/etc/greetd/config.toml"
SWITCH_HELPER="/usr/local/bin/deckify-session-switch"
OS_SESSION_SELECT="/usr/lib/os-session-select"
SUDOERS_FILE="/etc/sudoers.d/deckify-session-switch"
SWHKD_CONF="/etc/swhkd/swhkdrc"
ICON_NAME="steam-gaming-return"
SHORTCUT="Return_to_Gaming_Mode.desktop"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"

c_info() { echo -e "\n\e[36m[*]\e[0m $1"; }
c_ok()   { echo -e "\e[32m[ok]\e[0m $1"; }
c_warn() { echo -e "\e[33m[!]\e[0m $1"; }
c_err()  { echo -e "\e[31m[x]\e[0m $1" >&2; }

if [ "$EUID" -eq 0 ]; then
    c_err "Run this WITHOUT root/sudo — it will sudo where needed."
    exit 1
fi

echo -e "\n\e[1;33mCosmic Deckify — Uninstaller\e[0m"
echo    "This will REMOVE:"
echo    "  • swhkd.service (system) and swhks.service (user), and swhkd-git"
echo    "  • gamescope-session-steam-git / gamescope-session-git"
echo    "  • $OS_SESSION_SELECT and $SWITCH_HELPER"
echo    "  • $SUDOERS_FILE"
echo    "  • the gamescope-session/cosmic-session update pacman hooks + sync script"
echo    "  • 'Return to Gaming Mode' shortcut (desktop + app menu) and its icon"
echo    "  • greetd autologin (reset to the stock greeter — you'll get a login prompt)"
echo
echo -e "\e[1;30mThis will NOT remove: Steam, gamescope, COSMIC, mangohud, nvidia drivers,\e[0m"
echo -e "\e[1;30mor the nvidia_drm.modeset=1 modprobe config.\e[0m"
echo
read -rp "Proceed? (y/n): " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled. Nothing changed."; exit 0; }

sudo -v

# --- 1. swhkd hotkey daemon --------------------------------------------------
c_info "Stopping and removing swhkd/swhks..."
sudo systemctl disable --now swhkd.service 2>/dev/null || true
systemctl --user disable --now swhks.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/swhkd.service
rm -f "$HOME/.config/systemd/user/swhks.service"
sudo systemctl daemon-reload
systemctl --user daemon-reload
sudo rm -f "$SWHKD_CONF"
yay -Rns --noconfirm swhkd-git 2>/dev/null || paru -Rns --noconfirm swhkd-git 2>/dev/null || true
c_ok "swhkd removed."

# --- 2. gamescope session package -------------------------------------------
c_info "Removing gamescope-session-steam-git / gamescope-session-git..."
if pacman -Qq gamescope-session-steam-git &>/dev/null; then
    # Mark these explicit first so `-Rns`'s orphan-removal cascade can never take
    # them with it, regardless of what install reason they happen to carry.
    sudo pacman -D --asexplicit gamescope steam 2>/dev/null || true
    yay -Rns --noconfirm gamescope-session-steam-git gamescope-session-git 2>/dev/null \
        || paru -Rns --noconfirm gamescope-session-steam-git gamescope-session-git 2>/dev/null \
        || c_warn "Could not remove automatically — remove by hand if needed."
    c_ok "Removed."
else
    c_warn "Not installed (skipped)."
fi

# --- 3. hook, helper, sudoers ------------------------------------------------
c_info "Removing os-session-select hook, switch helper, and sudoers rule..."
sudo rm -f "$OS_SESSION_SELECT" "$SWITCH_HELPER" "$SUDOERS_FILE"
sudo rm -f /etc/pacman.d/hooks/deckify-gamescope-session.hook /etc/pacman.d/hooks/deckify-cosmic-session.hook /usr/local/bin/deckify-sync-session
c_ok "Removed."

# --- 4. shortcut + icon ------------------------------------------------------
c_info "Removing shortcut and icon..."
rm -f "$DESKTOP_DIR/$SHORTCUT" "$HOME/.local/share/applications/$SHORTCUT"
rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png"
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
c_ok "Removed."

# --- 5. greetd autologin -----------------------------------------------------
if [ -f "$GREETD_CONF" ]; then
    c_info "Resetting greetd to its stock (non-autologin) config..."
    sudo cp "$GREETD_CONF" "$GREETD_CONF.deckify.bak" 2>/dev/null || true
    sudo tee "$GREETD_CONF" >/dev/null <<'EOF'
[terminal]
vt = 1

[default_session]
command = "agreety --cmd /bin/sh"
user = "greeter"
EOF
    c_ok "greetd reset (backup at $GREETD_CONF.deckify.bak)."
else
    c_warn "$GREETD_CONF not found (skipped)."
fi

# install.sh disables cosmic-greeter.service (its own greeter+greetd pair) and
# enables plain greetd.service so this project's switch helper controls the
# real display manager. Reverse that here so COSMIC's native graphical login
# screen comes back instead of leaving the machine on the stock-agreety config
# above.
if systemctl list-unit-files cosmic-greeter.service &>/dev/null; then
    c_info "Restoring cosmic-greeter.service as the display manager..."
    sudo systemctl disable greetd.service 2>/dev/null || true
    sudo systemctl enable cosmic-greeter.service
    c_ok "cosmic-greeter.service restored (takes effect on reboot)."
fi

echo
c_ok "Uninstall complete."
echo    "  • Reboot to apply the display-manager change cleanly."
