#!/bin/bash
#
# Cosmic Deckify — vanilla Arch + COSMIC + gamescope, hotkey-switched
# ===========================================================================
# Sets up a SteamOS-style Gaming Mode (gamescope + Steam Big Picture) on a
# vanilla Arch install running COSMIC, and wires Super+Shift+S / Super+Shift+R
# as global hotkeys to switch between COSMIC and Gaming Mode.
#
# Architecture notes:
#   * COSMIC on Arch boots via greetd + cosmic-greeter, not SDDM. greetd's
#     `default_session` can be pointed straight at a real session command —
#     per greetd(1)/(5), that IS its auto-login mechanism. greetd only reads
#     config.toml once, at its own startup (no reload support), so switching
#     sessions means editing config.toml and restarting greetd.service, not
#     just logging out.
#   * gamescope-session-steam-git (AUR) ships its own /usr/bin/steamos-session-select,
#     a thin dispatcher that execs /usr/lib/os-session-select (or
#     /usr/libexec/os-session-select) if present. This script writes that
#     file instead of the package's own, so a package update can't silently
#     revert the switching logic.
#   * Super+Shift+R has to work from *inside* gamescope, where COSMIC (and its
#     keybinding system) isn't running. triggerhappy reads raw evdev directly,
#     below any Wayland compositor, so it keeps working no matter which
#     session has the screen. It ships no pre-made trigger config for this,
#     so this script writes the trigger file and systemd unit.
#   * NVIDIA's proprietary driver doesn't reliably release DRM master to a
#     second compositor on a live handoff, so this never attempts one — see
#     the generated switch helper for the teardown/barrier approach used
#     instead, with a full-reboot fallback if that ever proves insufficient.
#
# Run without sudo — it will sudo where needed.
# ===========================================================================

set -uo pipefail

GREETD_CONF="/etc/greetd/config.toml"
SESSION_LAUNCH="/usr/local/bin/deckify-session-launch"
SWITCH_HELPER="/usr/local/bin/deckify-session-switch"
OS_SESSION_SELECT="/usr/lib/os-session-select"
SUDOERS_FILE="/etc/sudoers.d/deckify-session-switch"
THD_CONF="/etc/triggerhappy/triggers.d/deckify.conf"
ICON_NAME="steam-gaming-return"
SHORTCUT="Return_to_Gaming_Mode.desktop"
COSMIC_CMD="/usr/bin/start-cosmic"
GAMESCOPE_CMD="gamescope-session-plus steam"
STATUS_USER="${SUDO_USER:-$(whoami)}"
TARGET_USER="$(whoami)"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
STATE_FILE_NAME=".local/state/deckify-session-target"
BACKLIGHT_DEV="$(ls /sys/class/backlight 2>/dev/null | head -n1)"

c_info() { echo -e "\n\e[36m[*]\e[0m $1"; }
c_ok()   { echo -e "\e[32m[ok]\e[0m $1"; }
c_warn() { echo -e "\e[33m[!]\e[0m $1"; }
c_err()  { echo -e "\e[31m[x]\e[0m $1" >&2; }

# ---------------------------------------------------------------------------
# --status: read-only diagnostic dump, safe to run any time, as either the
# target user or root (via sudo — some sections need root to read debugfs).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--status" ]; then
    status_home="$(getent passwd "$STATUS_USER" | cut -d: -f6)"
    echo "== display-manager.service alias =="
    systemctl show -p Id display-manager.service 2>&1
    echo
    echo "== greetd.service / cosmic-greeter.service =="
    systemctl is-enabled greetd.service cosmic-greeter.service 2>&1
    systemctl is-active  greetd.service cosmic-greeter.service 2>&1
    echo
    echo "== live greetd config: $GREETD_CONF =="
    cat "$GREETD_CONF" 2>&1
    echo
    echo "== state file: $status_home/$STATE_FILE_NAME =="
    cat "$status_home/$STATE_FILE_NAME" 2>&1
    echo
    echo "== current DRM master holder =="
    if [ "$(id -u)" -eq 0 ]; then
        for f in /sys/kernel/debug/dri/*/clients; do echo "-- $f --"; cat "$f" 2>&1; done
    else
        echo "(needs root — re-run: sudo bash install.sh --status)"
    fi
    echo
    echo "== triggerhappy.service =="
    systemctl is-enabled triggerhappy.service 2>&1
    systemctl is-active triggerhappy.service 2>&1
    exit 0
fi

if [ "$EUID" -eq 0 ]; then
    c_err "Run this WITHOUT root/sudo — it will sudo where needed. (For read-only"
    c_err "status, 'sudo bash install.sh --status' is fine.)"
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
c_info "[1/14] Checking for an AUR helper..."
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
c_info "[2/14] Ensuring multilib is enabled..."
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
c_info "[3/14] Installing COSMIC desktop + greetd..."
sudo pacman -S --needed --noconfirm cosmic greetd greetd-tuigreet
for pkg in cosmic-session cosmic-comp cosmic-greeter greetd; do
    pacman -Qq "$pkg" &>/dev/null || { c_err "$pkg failed to install — check the pacman output above (e.g. a file conflict) and re-run."; exit 1; }
done
c_ok "COSMIC + greetd installed."

# ---------------------------------------------------------------------------
# 4. Steam + gamescope
# ---------------------------------------------------------------------------
c_info "[4/14] Installing Steam + gamescope..."
sudo pacman -S --needed --noconfirm steam gamescope
for pkg in steam gamescope; do
    pacman -Qq "$pkg" &>/dev/null || { c_err "$pkg failed to install — check the pacman output above and re-run."; exit 1; }
done
c_ok "Steam + gamescope installed."

# ---------------------------------------------------------------------------
# 5. gamescope-session-steam-git (AUR)
# ---------------------------------------------------------------------------
c_info "[5/14] Installing gamescope-session-steam-git (AUR)..."
"$AUR_HELPER" -S --noconfirm --needed aur/gamescope-session-git aur/gamescope-session-steam-git
if ! pacman -Qq gamescope-session-steam-git &>/dev/null; then
    c_err "gamescope-session-steam-git did not install. Re-run after checking for AUR conflicts."
    exit 1
fi
c_ok "gamescope-session-steam-git installed."
[ -f /usr/share/wayland-sessions/gamescope-session-steam.desktop ] \
    || c_warn "Expected session file not found — the AUR package may have changed layout."

# ---------------------------------------------------------------------------
# 6. triggerhappy (AUR) — global hotkey daemon, works underneath any compositor
# ---------------------------------------------------------------------------
c_info "[6/14] Installing triggerhappy (AUR)..."
"$AUR_HELPER" -S --noconfirm --needed aur/triggerhappy
command -v thd &>/dev/null || { c_err "triggerhappy install failed."; exit 1; }
c_ok "triggerhappy installed."

# ---------------------------------------------------------------------------
# 7. NVIDIA: nvidia_drm.modeset=1 + early KMS (only if NVIDIA present)
# ---------------------------------------------------------------------------
c_info "[7/14] NVIDIA modeset check..."
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
# 8. Session launcher + greetd config: state-file driven autologin.
#    greetd only reads config.toml once, at its own startup (no SIGHUP/
#    reload support) — so config.toml is written ONCE here and never
#    touched again by a switch. Switching instead rewrites a small state
#    file that $SESSION_LAUNCH re-reads fresh every time greetd (re)execs
#    it, so COSMIC_CMD/GAMESCOPE_CMD only ever need to live in one place.
# ---------------------------------------------------------------------------
c_info "[8/14] Writing $SESSION_LAUNCH..."
sudo tee "$SESSION_LAUNCH" >/dev/null <<EOF
#!/bin/bash
# Generated by Cosmic Deckify. Execed by greetd as the configured
# default_session command, every time a session starts. Reads the target
# session out of a per-user state file so switching never has to touch
# greetd's config.toml.
set -uo pipefail

COSMIC_CMD="$COSMIC_CMD"
GAMESCOPE_CMD="$GAMESCOPE_CMD"
STATE_FILE="\$HOME/$STATE_FILE_NAME"

target="cosmic"
if [ -r "\$STATE_FILE" ]; then
    read -r target < "\$STATE_FILE" || target="cosmic"
fi

case "\$target" in
    gamescope) exec \$GAMESCOPE_CMD ;;
    *)         exec \$COSMIC_CMD ;;
esac
EOF
sudo chmod 755 "$SESSION_LAUNCH"
sudo chown root:root "$SESSION_LAUNCH"
c_ok "$SESSION_LAUNCH written."

c_info "Configuring greetd autologin (state-file driven)..."
if [ -f "$GREETD_CONF" ] && [ ! -f "$GREETD_CONF.deckify-orig" ]; then
    sudo cp "$GREETD_CONF" "$GREETD_CONF.deckify-orig"
    c_ok "Backed up pristine $GREETD_CONF to $GREETD_CONF.deckify-orig."
fi
sudo tee "$GREETD_CONF" >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "$SESSION_LAUNCH"
user = "$TARGET_USER"
EOF
c_ok "greetd will auto-launch $SESSION_LAUNCH (state-file driven) for $TARGET_USER on VT1."

mkdir -p "$TARGET_HOME/$(dirname "$STATE_FILE_NAME")"
[ -f "$TARGET_HOME/$STATE_FILE_NAME" ] || echo cosmic > "$TARGET_HOME/$STATE_FILE_NAME"
c_ok "Session target state file ready ($TARGET_HOME/$STATE_FILE_NAME)."

# The `cosmic-greeter` package ships its OWN systemd unit (cosmic-greeter.service)
# that runs a *second*, independent greetd process against a different config
# file (/etc/greetd/cosmic-greeter.toml) and claims the display-manager.service
# alias for itself. If that unit stays enabled, deckify-session-switch's edits
# to $GREETD_CONF and `systemctl restart greetd.service` are a no-op at boot,
# and a live switch starts a second greetd fighting the first over VT1/DRM
# master — this is what a black screen with a flashing cursor after a switch
# means. Make plain greetd.service the one true display manager instead.
if systemctl list-unit-files cosmic-greeter.service &>/dev/null; then
    c_info "Disabling cosmic-greeter.service's own greeter so plain greetd.service"
    c_info "(the one this script controls) owns display-manager.service..."
    sudo systemctl disable cosmic-greeter.service 2>/dev/null || true
    sudo systemctl enable greetd.service
    c_ok "greetd.service is now the active display manager (takes effect on reboot)."
fi

# ---------------------------------------------------------------------------
# 9. Root switch helper — the only thing sudoers grants NOPASSWD access to
# ---------------------------------------------------------------------------
c_info "[9/14] Writing $SWITCH_HELPER..."
sudo tee "$SWITCH_HELPER" >/dev/null <<EOF
#!/bin/bash
# Generated by Cosmic Deckify.
#
# A live compositor-to-compositor handoff isn't safe on NVIDIA (it doesn't
# reliably release DRM master to a second compositor in place), so this
# never does one. Every switch: writes the new target to a state file (read
# by $SESSION_LAUNCH), tears the outgoing session down through logind,
# quiesces onto a bare VT so fbcon becomes the intermediate DRM-master
# owner, and polls for the outgoing compositor to actually leave the GPU's
# client list (a fixed sleep isn't reliable enough here) before letting
# greetd start the next one. Falls back to a full reboot if the barrier
# never clears, rather than starting a compositor onto a possibly still-
# contested GPU.
set -uo pipefail

TARGET_USER="$TARGET_USER"
TARGET_UID="$TARGET_UID"
STATE_FILE="$TARGET_HOME/$STATE_FILE_NAME"

# "barrier" (default): quiesce + poll for the outgoing compositor to release
# DRM master, then restart greetd. Falls back to a reboot automatically if
# the barrier times out.
# "reboot": skip the barrier and always reboot immediately — slower, but a
# known-clean escape hatch if the barrier ever proves unreliable on this
# hardware/driver combo.
SWITCH_METHOD="barrier"

# How long (seconds) to wait for the outgoing compositor to release DRM
# master before giving up and falling back to a reboot.
BARRIER_TIMEOUT_SEC=8

# A VT nothing else uses, so fbcon can become the intermediate DRM-master
# owner between the outgoing and incoming compositor (this is what
# nvidia_drm's fbdev=1 option enables). Must differ from \$GREETD_CONF's
# own \`vt\` (1).
QUIESCE_VT=2

log() { echo "deckify-switch: \$*" >&2; command -v logger &>/dev/null && logger -t deckify-switch "\$*" 2>/dev/null || true; }

case "\${1:-}" in
    gamescope) target="gamescope" ;;
    desktop)   target="cosmic" ;;
    --diagnose)
        echo "== loginctl sessions =="; loginctl list-sessions 2>&1
        echo; echo "== DRM clients =="
        for f in /sys/kernel/debug/dri/*/clients; do echo "-- \$f --"; cat "\$f" 2>&1; done
        echo; echo "== eDP connector (modetest -c) =="; modetest -c 2>&1
        echo; echo "== state file (\$STATE_FILE) =="; cat "\$STATE_FILE" 2>&1
        exit 0 ;;
    *)
        echo "Usage: \$0 {gamescope|desktop|--diagnose}" >&2
        exit 1 ;;
esac

log "switch requested: -> \$target (method=\$SWITCH_METHOD)"

# 1. Write the new target FIRST, before tearing anything down — if
#    everything below falls through to the reboot fallback, the reboot
#    still lands on the right session.
install -d -o "\$TARGET_USER" -g "\$TARGET_USER" "\$(dirname "\$STATE_FILE")"
echo "\$target" > "\$STATE_FILE"
chown "\$TARGET_USER:\$TARGET_USER" "\$STATE_FILE"

# 2. Snapshot the eDP connector's colour-management state purely for
#    diagnostics (compare against \`$SWITCH_HELPER --diagnose\` afterwards
#    if colours/brightness look wrong again) — not required for the switch.
EDP_CONN="\$(modetest -c 2>/dev/null | awk '\$0 ~ /eDP/ {print \$1; exit}')"
[ -n "\${EDP_CONN:-}" ] && modetest -c 2>/dev/null > "/tmp/deckify-connector-before-\$\$.log"

# 3. Best-effort: ask the outgoing session's systemd --user manager to stop
#    its graphical-session target synchronously. This alone is NOT the
#    barrier (see step 6) — systemd reports the stop job "done" as soon as
#    the process is reaped, which is before the kernel/NVIDIA driver has
#    necessarily finished revoking that process's DRM master.
sudo -u "\$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/\$TARGET_UID" \\
    systemctl --user stop gamescope-session.target cosmic-session.target 2>/dev/null || true
sudo -u "\$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/\$TARGET_UID" \\
    systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY 2>/dev/null || true

# 4. Terminate every login session on seat0 through logind — not just the
#    systemd --user targets above — so nothing is left holding a
#    conflicting claim on the seat (two "Active=yes" sessions on seat0 at
#    once can make cosmic-comp's SET_MASTER fail, even on a fresh boot).
for sid in \$(loginctl list-sessions --no-legend 2>/dev/null | awk '\$4=="seat0"{print \$1}'); do
    loginctl terminate-session "\$sid" 2>/dev/null || true
done

# 5. Quiesce: switch to a bare VT so fbcon becomes the intermediate DRM
#    master owner instead of nothing owning it (or the outgoing compositor
#    still half-owning it). A VT switch forces the kernel to run its
#    master-handoff path, a stronger signal than waiting on systemd alone.
chvt "\$QUIESCE_VT" 2>/dev/null || log "chvt to VT\$QUIESCE_VT failed (non-fatal, continuing)"

# 6. Barrier: poll until the OUTGOING compositor no longer shows up as a DRM
#    client at all — NOT "until nothing holds master": step 5 deliberately
#    hands master to fbcon as the intermediate owner, so a bare "is anyone
#    master" check would never clear and this would always time out.
still_held() {
    for f in /sys/kernel/debug/dri/*/clients; do
        [ -r "\$f" ] || { log "cannot read \$f (need root?) — treating barrier as satisfied"; continue; }
        awk 'NR>1 && (\$1=="cosmic-comp" || \$1=="gamescope-wl" || \$1=="gamescope") {found=1} END{exit !found}' "\$f" && return 0
    done
    return 1
}

freed=0
if [ "\$SWITCH_METHOD" != "reboot" ]; then
    ticks=\$((BARRIER_TIMEOUT_SEC * 5))
    i=0
    while [ "\$i" -lt "\$ticks" ]; do
        still_held || { freed=1; break; }
        sleep 0.2
        i=\$((i + 1))
    done
    if [ "\$freed" -eq 1 ]; then
        log "DRM master barrier cleared after ~\$(awk "BEGIN{printf \"%.1f\", \$i/5}")s"
    else
        log "DRM master barrier TIMED OUT after \${BARRIER_TIMEOUT_SEC}s"
    fi
fi

if [ "\$SWITCH_METHOD" = "reboot" ] || [ "\$freed" -ne 1 ]; then
    log "falling back to a full reboot for a guaranteed-clean handoff."
    systemctl reboot
    exit 0
fi

# 7. Connector-state reset: gamescope applies the panel's native wide-gamut
#    EDID colorimetry and can leave HDR metadata set; cosmic-comp never
#    resets either on its own. Reset both now, while nothing else holds DRM
#    master, before the next compositor starts and inherits whatever is
#    left. Best-effort/non-fatal by design — if colours are still wrong
#    afterwards, diff \`$SWITCH_HELPER --diagnose\` against
#    /tmp/deckify-connector-before-*.log to see which property didn't take.
if [ -n "\${EDP_CONN:-}" ]; then
    modetest -w "\$EDP_CONN:Colorspace:0" >/dev/null 2>&1 \\
        || log "connector Colorspace reset failed or unsupported (non-fatal)"
    modetest -w "\$EDP_CONN:HDR_OUTPUT_METADATA:0" >/dev/null 2>&1 \\
        || log "connector HDR_OUTPUT_METADATA clear failed or unsupported (non-fatal)"
fi

# greetd's own \`vt = 1\` config switches back to VT1 when it starts the next
# session-worker — no explicit chvt back needed here.
systemctl restart greetd.service
EOF
sudo chmod 755 "$SWITCH_HELPER"
sudo chown root:root "$SWITCH_HELPER"
c_ok "Switch helper written."

# ---------------------------------------------------------------------------
# 10. Self-healing pacman hooks — if gamescope-session-steam-git/gamescope-
#     session-git or cosmic-session ever change the Exec= line of their
#     wayland session (a rename, a new wrapper, etc.), GAMESCOPE_CMD/
#     COSMIC_CMD baked into $SESSION_LAUNCH would silently go stale. These
#     hooks fire on every install/upgrade of those packages and re-derive the
#     command from whatever .desktop file is actually installed, patching
#     $SESSION_LAUNCH. greetd's config.toml never needs touching here — it
#     always points at $SESSION_LAUNCH, never directly at a session command.
# ---------------------------------------------------------------------------
c_info "[10/14] Installing self-healing pacman hooks for session updates..."
SYNC_SCRIPT="/usr/local/bin/deckify-sync-session"
sudo tee "$SYNC_SCRIPT" >/dev/null <<'EOF'
#!/bin/bash
# Generated by Cosmic Deckify. Run by a pacman hook whenever the package
# owning a wayland session (gamescope-session-*-git, cosmic-session) is
# installed/upgraded.
#
# Usage: deckify-sync-session <DesktopNames-value> <VAR_NAME>
#   e.g.: deckify-sync-session gamescope GAMESCOPE_CMD
#         deckify-sync-session COSMIC    COSMIC_CMD
#
# Re-derives the session's Exec= line from whatever wayland-session file
# actually carries that DesktopNames value, and patches it into
# deckify-session-launch's VAR_NAME so an upstream change to the session
# command can't silently break the switch.
set -uo pipefail

SESSION_LAUNCH="/usr/local/bin/deckify-session-launch"

desktop_names="${1:-}"
var_name="${2:-}"
if [ -z "$desktop_names" ] || [ -z "$var_name" ]; then
    echo "deckify: usage: $(basename "$0") <DesktopNames-value> <VAR_NAME>" >&2
    exit 1
fi

[ -f "$SESSION_LAUNCH" ] || exit 0

session_file="$(grep -l "^DesktopNames=${desktop_names}\$" /usr/share/wayland-sessions/*.desktop 2>/dev/null | head -n1)"
if [ -z "$session_file" ]; then
    echo "deckify: no wayland-session file with DesktopNames=$desktop_names found — nothing to sync" >&2
    exit 0
fi

new_cmd="$(sed -n 's/^Exec=//p' "$session_file" | head -n1)"
if [ -z "$new_cmd" ]; then
    echo "deckify: couldn't read Exec= from $session_file — nothing to sync" >&2
    exit 0
fi

old_cmd="$(sed -n "s/^${var_name}=\"\\(.*\\)\"\$/\\1/p" "$SESSION_LAUNCH")"
if [ "$new_cmd" = "$old_cmd" ]; then
    exit 0
fi

escape_repl() { printf '%s' "$1" | sed -e 's/[\&#]/\\&/g'; }
new_esc="$(escape_repl "$new_cmd")"

echo "deckify: $var_name changed on package update:" >&2
echo "  old: $old_cmd" >&2
echo "  new: $new_cmd" >&2

sed -i "s#^${var_name}=\".*\"\$#${var_name}=\"${new_esc}\"#" "$SESSION_LAUNCH"

echo "deckify: $var_name re-synced successfully." >&2
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
Exec = $SYNC_SCRIPT gamescope GAMESCOPE_CMD
EOF
sudo tee /etc/pacman.d/hooks/deckify-cosmic-session.hook >/dev/null <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = cosmic-session

[Action]
Description = Cosmic Deckify: re-syncing COSMIC session command...
When = PostTransaction
Exec = $SYNC_SCRIPT COSMIC COSMIC_CMD
EOF
c_ok "Self-healing pacman hooks installed (gamescope-session-*, cosmic-session)."

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
$TARGET_USER ALL=(root) NOPASSWD: $SWITCH_HELPER --diagnose
EOF
# Steam/gamescope's own brightness-fade animation writes the backlight via
# `sudo tee /sys/class/backlight/<dev>/brightness` (not systemd-logind's
# SetBrightness D-Bus call, which is what COSMIC's own slider uses) and has
# no interactive TTY to prompt on, so without this it silently fails on
# every attempt — every fade write is dropped and the backlight is left
# wherever it last was, which shows up as a too-bright screen after
# returning to the desktop.
if [ -n "$BACKLIGHT_DEV" ]; then
    echo "$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/tee /sys/class/backlight/$BACKLIGHT_DEV/brightness" >> "$SUDOERS_TMP"
else
    c_warn "No /sys/class/backlight device found — skipping the brightness sudoers grant."
fi
if sudo visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
    sudo install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
    c_ok "sudoers rule installed."
else
    c_err "Generated sudoers file failed validation — not installed. Session switching will prompt for a password."
fi
rm -f "$SUDOERS_TMP"

# ---------------------------------------------------------------------------
# 13. triggerhappy: hotkeys + systemd unit (none are shipped by the AUR package)
# ---------------------------------------------------------------------------
c_info "[13/14] Configuring Super+Shift+S / Super+Shift+R hotkeys..."

# Migrate off a previous install's swhkd/swhks (dropped for triggerhappy):
# swhkd's root+pkexec/client-server-IPC model needed a loginuid workaround,
# had an XDG_RUNTIME_DIR mismatch between the root daemon and its user-run
# IPC helper, and (in some builds) required launching via pkexec.
# triggerhappy is a single plain root daemon reading evdev directly, with
# none of that.
if systemctl list-unit-files swhkd.service &>/dev/null || [ -f "$HOME/.config/systemd/user/swhks.service" ]; then
    c_info "Removing previous swhkd/swhks hotkey daemon (migrated to triggerhappy)..."
    sudo systemctl disable --now swhkd.service 2>/dev/null || true
    systemctl --user disable --now swhks.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/swhkd.service
    sudo rm -rf /etc/systemd/system/swhkd.service.d
    rm -f "$HOME/.config/systemd/user/swhks.service"
    rm -rf "$HOME/.config/systemd/user/swhks.service.d"
    sudo systemctl daemon-reload
    systemctl --user daemon-reload
    sudo rm -f /etc/swhkd/swhkdrc
    "$AUR_HELPER" -Rns --noconfirm swhkd-git swhkd-git-debug 2>/dev/null || true
    sudo loginctl disable-linger "$TARGET_USER" 2>/dev/null || true
    c_ok "Old swhkd/swhks removed."
fi

sudo mkdir -p "$(dirname "$THD_CONF")"
sudo tee "$THD_CONF" >/dev/null <<'EOF'
# Generated by Cosmic Deckify.
# <event>	<value 1=press>	<command, runs as the --user configured below>
# Desktop (COSMIC) -> Gaming Mode
KEY_S+KEY_LEFTMETA+KEY_LEFTSHIFT	1	steamos-session-select gamescope

# Gaming Mode -> Desktop (works from inside gamescope: triggerhappy reads
# evdev directly, independent of whichever compositor currently owns the screen)
KEY_R+KEY_LEFTMETA+KEY_LEFTSHIFT	1	steamos-session-select desktop
EOF

THD_BIN="$(command -v thd)"
sudo tee /etc/systemd/system/triggerhappy.service >/dev/null <<EOF
[Unit]
Description=triggerhappy global hotkey daemon (Cosmic Deckify)
After=local-fs.target

[Service]
# thd opens /dev/input as root, then drops privileges to --user for
# everything else (including running triggered commands) -- so this is set
# to \$TARGET_USER rather than upstream's default "nobody", since the
# triggered commands go through a sudoers rule scoped to \$TARGET_USER.
# Type=simple rather than upstream's Type=notify: this AUR build's
# sd_notify support isn't guaranteed, and a stuck notify wedges the unit
# on every boot until it times out.
Type=simple
ExecStart=$THD_BIN --triggers $(dirname "$THD_CONF")/ --socket /run/thd.socket --user $TARGET_USER --deviceglob /dev/input/event*
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now triggerhappy.service

if systemctl is-active --quiet triggerhappy.service; then
    c_ok "Hotkeys active: Super+Shift+S (desktop->gaming), Super+Shift+R (gaming->desktop)."
else
    c_warn "triggerhappy did not report as active — hotkeys may not work until you check:"
    c_warn "  systemctl status triggerhappy.service"
fi

# ---------------------------------------------------------------------------
# 14. Desktop shortcut (mouse-driven fallback alongside the hotkey)
# ---------------------------------------------------------------------------
c_info "[14/14] Creating 'Return to Gaming Mode' shortcut..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.local/share/icons/hicolor/256x256/apps" "$HOME/.local/share/applications"
if [ -f "$SCRIPT_DIR/icons/${ICON_NAME}.png" ]; then
    cp "$SCRIPT_DIR/icons/${ICON_NAME}.png" "$HOME/.local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png"
else
    c_warn "Icon not found in $SCRIPT_DIR/icons/; shortcut will fall back to a generic icon."
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
echo "    has the screen, since triggerhappy reads raw input independent of it."
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
