#!/bin/bash
#
# uninstall.sh — Arch Deckify (COSMIC / NVIDIA edition)
# ---------------------------------------------------------------------------
# Reverses what install.sh set up. Removes the gamescope session, the
# steamos-session-select switcher, the sudoers rule, the shortcut + icon, and
# disables SDDM autologin (so you get a normal login greeter back).
#
# It does NOT remove general packages you may want to keep (Steam, gamescope,
# mangohud, ntfs-3g, wget, bluez) — only the deckify-specific gamescope session.
# ---------------------------------------------------------------------------

set -uo pipefail

SWITCHER="/usr/bin/steamos-session-select"
SDDM_CONF="/etc/sddm.conf"
SUDOERS_FILE="/etc/sudoers.d/sddm_config_edit"
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

echo -e "\n\e[1;33mArch Deckify — Uninstaller\e[0m"
echo    "This will REMOVE:"
echo    "  • gamescope-session-steam-git (the gaming session)"
echo    "  • $SWITCHER (session switcher)"
echo    "  • $SUDOERS_FILE (passwordless Session= rule)"
echo    "  • 'Return to Gaming Mode' shortcut (desktop + app menu) and its icon"
echo    "  • SDDM autologin (disabled — you'll get a normal greeter)"
echo
echo -e "\e[1;30mThis will NOT remove: Steam, gamescope, mangohud, ntfs-3g, wget, bluez,\e[0m"
echo -e "\e[1;30mor your desktop environment.\e[0m"
echo
read -rp "Proceed? (y/n): " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled. Nothing changed."; exit 0; }

sudo -v   # prime sudo

# --- 1. gamescope session package -----------------------------------------
c_info "Removing gamescope-session-steam-git..."
if pacman -Qq 2>/dev/null | grep -q '^gamescope-session-steam-git$'; then
    yay -Rns --noconfirm gamescope-session-steam-git 2>/dev/null \
        || paru -Rns --noconfirm gamescope-session-steam-git 2>/dev/null \
        || sudo pacman -Rns --noconfirm gamescope-session-steam-git 2>/dev/null \
        || c_warn "Could not remove the package automatically — remove it by hand if needed."
    c_ok "gamescope-session-steam-git removed."
else
    c_warn "gamescope-session-steam-git not installed (skipped)."
fi

# --- 2. switcher + sudoers -------------------------------------------------
c_info "Removing switcher and sudoers rule..."
sudo rm -f "$SWITCHER" "$SUDOERS_FILE"
c_ok "Removed $SWITCHER and the sudoers rule."

# --- 3. shortcuts + icon ---------------------------------------------------
c_info "Removing shortcut and icon..."
rm -f "$DESKTOP_DIR/$SHORTCUT" "$HOME/.local/share/applications/$SHORTCUT"
rm -f "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png"
command -v gtk-update-icon-cache >/dev/null \
    && gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
command -v update-desktop-database >/dev/null \
    && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
c_ok "Shortcut and icon removed."

# --- 4. SDDM autologin -----------------------------------------------------
if [ -f "$SDDM_CONF" ]; then
    c_info "Disabling SDDM autologin..."
    sudo cp "$SDDM_CONF" "$SDDM_CONF.deckify.bak" 2>/dev/null || true
    sudo sed -i 's/^Relogin=true/Relogin=false/; s/^User=.*/User=/; s/^Session=.*/Session=/' "$SDDM_CONF"
    c_ok "Autologin disabled (backup at $SDDM_CONF.deckify.bak)."
else
    c_warn "$SDDM_CONF not found (skipped)."
fi

# --- 5. optional: remove the ~/arch-deckify working dir --------------------
if [ -d "$HOME/arch-deckify" ]; then
    read -rp $'\nAlso delete the ~/arch-deckify folder (downloaded icon etc.)? (y/n): ' d
    if [[ "$d" =~ ^[Yy]$ ]]; then
        rm -rf "$HOME/arch-deckify"
        c_ok "Removed ~/arch-deckify."
    fi
fi

echo
c_ok "Uninstall complete."
echo    "  • Reboot to return to a normal SDDM login greeter."
echo    "  • If you removed the CachyOS gamescope session during install and want it"
echo    "    back:  sudo pacman -S gamescope-session-cachyos"
