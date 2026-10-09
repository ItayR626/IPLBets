#!/usr/bin/env bash
# =============================================================================
# cachy-omarchy.sh - Omarchy-style Hyprland setup for a fresh CachyOS install
# =============================================================================
# 1. Install CachyOS and choose "No Desktop" in the installer (bash as shell
#    is recommended, but the script switches you to bash if you pick fish/zsh).
# 2. Boot, log in on the TTY, connect to the internet, then run as YOUR USER:
#        bash cachy-omarchy.sh
#    Non-interactive:  AUTOLOGIN=1 APPS=1 bash cachy-omarchy.sh
# 3. Reboot -> SDDM -> Hyprland (uwsm).
#
# Your old configs are backed up to ~/.config-backup-<timestamp>.
# Targets Hyprland >= 0.55 (Lua config). Does not touch bootloader/partitions.
# =============================================================================

set -uo pipefail

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXX %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]]            && die "Run as your normal user, not root."
command -v pacman >/dev/null || die "This script is for CachyOS / Arch only."
grep -qiE 'cachyos|arch' /etc/os-release || warn "Not CachyOS/Arch - continuing anyway."
ping -c1 -W3 archlinux.org >/dev/null 2>&1 || die "No internet connection."

# ----------------------------------------------------------------- questions
ask() { # ask VAR "question" default(y|n)  - skipped if VAR already set in env
  local var=$1 q=$2 def=$3 ans
  if [[ -n "${!var:-}" ]]; then return; fi
  if [[ -t 0 ]]; then
    read -rp "$q [y/n, default $def]: " ans
    ans=${ans:-$def}
  else
    ans=$def
  fi
  [[ $ans =~ ^[Yy] ]] && printf -v "$var" 1 || printf -v "$var" 0
}
ask AUTOLOGIN "Skip the login screen (auto-login, only sensible with disk encryption)?" n
ask APPS      "Install extra apps (LibreOffice, Obsidian, Signal, Spotify)?" y

# keep sudo alive during long installs
sudo -v || die "sudo failed"
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
KEEPALIVE=$!
trap 'kill $KEEPALIVE 2>/dev/null' EXIT

CFG="$HOME/.config"
BACKUP="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CFG" "$BACKUP" "$HOME/.local/bin"

backup() {
  local d
  for d in "$@"; do
    [[ -e "$CFG/$d" ]] && mv "$CFG/$d" "$BACKUP/" 2>/dev/null
  done
}

# ---------------------------------------------------------------- hardware
GPU_INFO=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)
HAS_NVIDIA=0; grep -qi nvidia <<<"$GPU_INFO" && HAS_NVIDIA=1
IS_LAPTOP=0;  compgen -G "/sys/class/power_supply/BAT*" >/dev/null && IS_LAPTOP=1

# ---------------------------------------------------------------- packages
say "Updating system"
sudo pacman -Syu --noconfirm || die "System update failed"

if   command -v paru >/dev/null; then AUR=paru
elif command -v yay  >/dev/null; then AUR=yay
else
  say "Installing yay (AUR helper)"
  sudo pacman -S --needed --noconfirm git base-devel
  tmp=$(mktemp -d)
  git clone https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
    && (cd "$tmp/yay-bin" && makepkg -si --noconfirm)
  AUR=yay
fi

PKGS=(
  # compositor, session, portals, Xwayland
  hyprland uwsm hypridle hyprlock hyprpaper hyprpolkitagent polkit
  xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
  qt5-wayland qt6-wayland xorg-xwayland xorg-server
  # login manager
  sddm
  # bar, launcher, notifications, OSD
  waybar fuzzel mako swayosd libnotify
  # apps
  alacritty nautilus chromium imv mpv evince
  # files / mounting / keyring
  gvfs udisks2 gnome-keyring libsecret
  # screenshots, clipboard, media, brightness
  grim slurp satty wl-clipboard cliphist brightnessctl playerctl
  # audio
  pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils wiremix
  # network + bluetooth
  networkmanager bluez bluez-utils bluetui
  # fonts + theming
  ttf-jetbrains-mono-nerd noto-fonts noto-fonts-emoji
  gnome-themes-extra adwaita-icon-theme
  # xdg helpers
  xdg-utils xdg-user-dirs
  # shell + CLI
  starship eza bat fd ripgrep fzf zoxide btop fastfetch tree jq unzip wget
  curl pciutils python
  # dev
  base-devel git github-cli lazygit neovim tree-sitter-cli mise
  docker docker-compose docker-buildx lazydocker
)
(( HAS_NVIDIA )) && PKGS+=(libva-nvidia-driver)
(( IS_LAPTOP ))  && PKGS+=(power-profiles-daemon upower)

FAILED=()
install_list() {
  # fast path: one transaction; slow path: one by one, pacman then AUR
  sudo pacman -S --needed --noconfirm "$@" && return 0
  warn "Bulk install failed - retrying package by package"
  local p
  for p in "$@"; do
    sudo pacman -S --needed --noconfirm "$p" \
      || "$AUR" -S --needed --noconfirm "$p" \
      || FAILED+=("$p")
  done
}

say "Installing packages"
install_list "${PKGS[@]}"

if (( APPS )); then
  say "Installing extra apps"
  for p in libreoffice-fresh obsidian signal-desktop spotify; do
    sudo pacman -S --needed --noconfirm "$p" 2>/dev/null \
      || "$AUR" -S --needed --noconfirm "$p" \
      || FAILED+=("$p")
  done
fi

# --- Hyprland must be new enough for the Lua config used below
HV=$(pacman -Q hyprland 2>/dev/null | awk '{print $2}' | cut -d- -f1)
[[ -n $HV ]] || die "Hyprland did not install - check the errors above."
if [[ $(printf '%s\n' 0.55.0 "$HV" | sort -V | head -n1) != 0.55.0 ]]; then
  die "Hyprland $HV is older than 0.55 (no Lua config support). Run: sudo pacman -Syu"
fi
say "Hyprland $HV detected"

# ---------------------------------------------------------------- shell
if [[ "$(getent passwd "$USER" | cut -d: -f7)" != */bash ]]; then
  say "Switching login shell to bash (like Omarchy)"
  sudo chsh -s /bin/bash "$USER"
fi

# ---------------------------------------------------------------- services
say "Enabling services"
sudo systemctl enable bluetooth.service
sudo systemctl enable NetworkManager.service
sudo systemctl enable docker.service
sudo systemctl enable swayosd-libinput-backend.service 2>/dev/null
(( IS_LAPTOP )) && sudo systemctl enable power-profiles-daemon.service
sudo systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null
sudo usermod -aG docker "$USER"
xdg-user-dirs-update
mkdir -p "$HOME/Pictures/Screenshots"

# ---------------------------------------------------------------- NVIDIA
if (( HAS_NVIDIA )); then
  say "NVIDIA GPU detected"
  if ! pacman -Q nvidia-utils >/dev/null 2>&1; then
    warn "No NVIDIA driver installed. The CachyOS installer normally adds it;"
    warn "if Hyprland fails to start, run:  sudo chwd -a   (CachyOS hardware tool)"
  fi
  echo 'options nvidia_drm modeset=1 fbdev=1' | sudo tee /etc/modprobe.d/nvidia-drm.conf >/dev/null
fi

# ---------------------------------------------------------------- theme
# Tokyo Night. ~/.config/cachy-omarchy/theme remembers the active colors so the
# theme switcher (SUPER+K) knows what to replace.
BG="1a1b26"; FG="c0caf5"; AC="7aa2f7"; DIM="565f89"; RED="f7768e"; GREEN="9ece6a"
mkdir -p "$CFG/cachy-omarchy"
echo "$BG $FG $AC" > "$CFG/cachy-omarchy/theme"

backup hypr waybar mako fuzzel alacritty starship.toml gtk-3.0 gtk-4.0
[[ -f "$HOME/.bashrc" ]] && cp "$HOME/.bashrc" "$BACKUP/.bashrc"

# ---------------------------------------------------------------- Hyprland (Lua)
say "Writing Hyprland config (hyprland.lua)"
mkdir -p "$CFG/hypr"

cat > "$CFG/hypr/hyprland.lua" <<'EOF'
-- ~/.config/hypr/hyprland.lua  (generated by cachy-omarchy.sh)
-- Wiki: https://wiki.hypr.land/Configuring/Start/

local mainMod     = "SUPER"
local terminal    = "uwsm app -- alacritty"
local fileManager = "uwsm app -- nautilus --new-window"
local browser     = "uwsm app -- chromium"
local menu        = "fuzzel"

---- MONITORS ----
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

---- ENVIRONMENT ----
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")

---- AUTOSTART ----
hl.on("hyprland.start", function()
  hl.exec_cmd("uwsm app -- waybar")
  hl.exec_cmd("uwsm app -- mako")
  hl.exec_cmd("uwsm app -- swayosd-server")
  hl.exec_cmd("uwsm app -- hypridle")
  hl.exec_cmd("uwsm app -- hyprpaper")
  hl.exec_cmd("systemctl --user start hyprpolkitagent")
  hl.exec_cmd("wl-paste --watch cliphist store")
  hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme prefer-dark")
end)

---- LOOK AND FEEL ----
hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 10,
    border_size = 2,
    col = {
      active_border = { colors = { "rgba(7aa2f7ee)", "rgba(bb9af7ee)" }, angle = 45 },
      inactive_border = "rgba(414868aa)",
    },
    resize_on_border = true,
    allow_tearing = false,
    layout = "dwindle",
  },
  decoration = {
    rounding = 8,
    rounding_power = 2,
    active_opacity = 1.0,
    inactive_opacity = 0.97,
    shadow = { enabled = true, range = 12, render_power = 3, color = 0xee1a1a1a },
    blur = { enabled = true, size = 5, passes = 2, vibrancy = 0.17 },
  },
  animations = { enabled = true },
  dwindle = { preserve_split = true },
  misc = {
    force_default_wallpaper = 0,
    disable_hyprland_logo = true,
  },
  input = {
    kb_layout = "us",
    follow_mouse = 1,
    sensitivity = 0,
    numlock_by_default = true,
    touchpad = { natural_scroll = true },
  },
})

hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
hl.curve("linear",       { type = "bezier", points = { {0, 0}, {1, 1} } })
hl.curve("quick",        { type = "bezier", points = { {0.15, 0}, {0.1, 1} } })

hl.animation({ leaf = "global",     enabled = true, speed = 10,  bezier = "default" })
hl.animation({ leaf = "border",     enabled = true, speed = 5.4, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn",  enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.5, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fade",       enabled = true, speed = 3,   bezier = "quick" })
hl.animation({ leaf = "layers",     enabled = true, speed = 3.8, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4,   bezier = "easeOutQuint", style = "slide" })

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

---- KEYBINDINGS (Omarchy-style) ----
local function sh(cmd) return hl.dsp.exec_cmd(cmd) end

-- apps
hl.bind(mainMod .. " + Return", sh(terminal))
hl.bind(mainMod .. " + space",  sh(menu))
hl.bind(mainMod .. " + B",      sh(browser))
hl.bind(mainMod .. " + F",      sh(fileManager))
hl.bind(mainMod .. " + T",      sh(terminal .. " -e btop"))
hl.bind(mainMod .. " + G",      sh(terminal .. " -e lazygit"))
hl.bind(mainMod .. " + D",      sh(terminal .. " -e lazydocker"))
hl.bind(mainMod .. " + N",      sh(terminal .. " -e nvim"))

-- system
hl.bind(mainMod .. " + Escape", sh("power-menu"))
hl.bind(mainMod .. " + L",      sh("pidof hyprlock || hyprlock"))
hl.bind(mainMod .. " + K",      sh("theme-switch"))
hl.bind(mainMod .. " + C",      sh("cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"))

-- floating TUIs: network / bluetooth / audio
hl.bind(mainMod .. " + CTRL + W", sh(terminal .. " --class tui-float -e nmtui"))
hl.bind(mainMod .. " + CTRL + B", sh(terminal .. " --class tui-float -e bluetui"))
hl.bind(mainMod .. " + CTRL + A", sh(terminal .. " --class tui-float -e wiremix"))

-- window management
hl.bind(mainMod .. " + W", hl.dsp.window.close())
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"))
hl.bind(mainMod .. " + CTRL + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))

hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.swap({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.swap({ direction = "right" }))
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.swap({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.swap({ direction = "down" }))

hl.bind(mainMod .. " + minus", hl.dsp.window.resize({ x = -100, y = 0, relative = true }), { repeating = true })
hl.bind(mainMod .. " + equal", hl.dsp.window.resize({ x = 100,  y = 0, relative = true }), { repeating = true })
hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.window.resize({ x = 0, y = -100, relative = true }), { repeating = true })
hl.bind(mainMod .. " + SHIFT + equal", hl.dsp.window.resize({ x = 0, y = 100,  relative = true }), { repeating = true })

-- workspaces 1-10
for i = 1, 10 do
  local key = i % 10
  hl.bind(mainMod .. " + " .. key,           hl.dsp.focus({ workspace = i }))
  hl.bind(mainMod .. " + SHIFT + " .. key,   hl.dsp.window.move({ workspace = i }))
end
hl.bind(mainMod .. " + Tab",         hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + SHIFT + Tab", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse_down",  hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",    hl.dsp.focus({ workspace = "e-1" }))

-- scratchpad
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- screenshots
hl.bind("Print",         sh([[grim -g "$(slurp)" - | satty -f - -o "$HOME/Pictures/Screenshots/shot-$(date +%s).png" --copy-command wl-copy]]))
hl.bind("SHIFT + Print", sh("grim - | wl-copy"))

-- volume / brightness (SwayOSD draws the popups) / media
hl.bind("XF86AudioRaiseVolume",  sh("swayosd-client --output-volume raise"),      { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  sh("swayosd-client --output-volume lower"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",         sh("swayosd-client --output-volume mute-toggle"), { locked = true })
hl.bind("XF86AudioMicMute",      sh("swayosd-client --input-volume mute-toggle"),  { locked = true })
hl.bind("XF86MonBrightnessUp",   sh("swayosd-client --brightness raise"),         { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", sh("swayosd-client --brightness lower"),         { locked = true, repeating = true })
hl.bind("XF86AudioNext",  sh("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", sh("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  sh("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  sh("playerctl previous"),   { locked = true })

---- WINDOW RULES ----
hl.window_rule({
  name = "suppress-maximize-events",
  match = { class = ".*" },
  suppress_event = "maximize",
})

hl.window_rule({
  name = "fix-xwayland-drags",
  match = { class = "^$", title = "^$", xwayland = true, float = true, fullscreen = false, pin = false },
  no_focus = true,
})

hl.window_rule({
  name = "floating-tuis",
  match = { class = "^tui-float$" },
  float = true,
  size = "800 500",
  center = true,
})

hl.window_rule({
  name = "nautilus-dialogs",
  match = { class = "^org.gnome.Nautilus$", title = "^(Properties|Rename.*)$" },
  float = true,
})
EOF

if (( HAS_NVIDIA )); then
  cat >> "$CFG/hypr/hyprland.lua" <<'EOF'

---- NVIDIA ----
hl.env("LIBVA_DRIVER_NAME", "nvidia")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")
EOF
fi

# --- wallpaper (solid color generated from the theme; replace with any image)
cat > "$HOME/.local/bin/mkwall" <<'EOF'
#!/usr/bin/env python3
"""mkwall RRGGBB  -> writes ~/.config/hypr/wall.png (solid color)"""
import os, struct, sys, zlib
hexcol = sys.argv[1].lstrip("#")
c = bytes.fromhex(hexcol)
w = h = 64
raw = b"".join(b"\x00" + c * w for _ in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
with open(os.path.expanduser("~/.config/hypr/wall.png"), "wb") as f:
    f.write(png)
EOF
chmod +x "$HOME/.local/bin/mkwall"
"$HOME/.local/bin/mkwall" "$BG"

cat > "$CFG/hypr/hyprpaper.conf" <<'EOF'
splash = false

wallpaper {
    monitor =
    path = ~/.config/hypr/wall.png
    fit_mode = cover
}
EOF

# --- idle + lock (hypr* helper tools still use the hyprlang syntax)
cat > "$HOME/.local/bin/screen-off" <<'EOF'
#!/usr/bin/env bash
hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'
EOF
cat > "$HOME/.local/bin/screen-on" <<'EOF'
#!/usr/bin/env bash
hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'
EOF
chmod +x "$HOME/.local/bin/screen-off" "$HOME/.local/bin/screen-on"

cat > "$CFG/hypr/hypridle.conf" <<'EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = screen-on
}

listener {
    timeout = 300
    on-timeout = loginctl lock-session
}

listener {
    timeout = 330
    on-timeout = screen-off
    on-resume = screen-on
}
EOF

cat > "$CFG/hypr/hyprlock.conf" <<EOF
background {
    color = rgb($BG)
}

input-field {
    size = 300, 50
    outline_thickness = 2
    inner_color = rgb($BG)
    outer_color = rgb($AC)
    font_color = rgb($FG)
    placeholder_text = Password...
    position = 0, -20
    halign = center
    valign = center
}

label {
    text = \$TIME
    color = rgb($FG)
    font_size = 72
    font_family = JetBrainsMono Nerd Font
    position = 0, 120
    halign = center
    valign = center
}
EOF

# ---------------------------------------------------------------- Waybar
say "Writing Waybar"
mkdir -p "$CFG/waybar"
cat > "$CFG/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "spacing": 0,
  "modules-left": ["hyprland/workspaces"],
  "modules-center": ["clock"],
  "modules-right": ["cpu", "pulseaudio", "bluetooth", "network", "battery"],
  "hyprland/workspaces": {
    "on-click": "activate",
    "format": "{name}",
    "persistent-workspaces": { "*": 5 }
  },
  "clock": {
    "format": "{:%A %H:%M}",
    "format-alt": "{:%d %B W%V %Y}",
    "tooltip": false
  },
  "cpu": {
    "format": "\uf2db",
    "interval": 5,
    "on-click": "alacritty -e btop"
  },
  "pulseaudio": {
    "format": "{icon}",
    "format-muted": "\uf026",
    "format-icons": { "default": ["\uf027", "\uf028"] },
    "tooltip-format": "{volume}%",
    "on-click": "alacritty --class tui-float -e wiremix"
  },
  "bluetooth": {
    "format": "\uf293",
    "format-disabled": "\uf294",
    "format-connected": "\uf293 {device_alias}",
    "on-click": "alacritty --class tui-float -e bluetui"
  },
  "network": {
    "format-wifi": "\uf1eb",
    "format-ethernet": "\uf0ac",
    "format-disconnected": "\uf071",
    "tooltip-format-wifi": "{essid} ({signalStrength}%)",
    "tooltip-format-ethernet": "{ifname}",
    "on-click": "alacritty --class tui-float -e nmtui"
  },
  "battery": {
    "format": "{capacity}% {icon}",
    "format-charging": "{capacity}% \uf0e7",
    "format-icons": ["\uf244", "\uf243", "\uf242", "\uf241", "\uf240"],
    "states": { "warning": 20, "critical": 10 }
  }
}
EOF

cat > "$CFG/waybar/style.css" <<EOF
* { font-family: "JetBrainsMono Nerd Font"; font-size: 13px; border: none; min-height: 0; }
window#waybar { background: transparent; color: #$FG; }
.modules-left, .modules-center, .modules-right {
  background: #$BG; margin: 4px 8px 0 8px; padding: 0 8px; border-radius: 8px;
}
#workspaces button { padding: 0 6px; color: #$DIM; background: transparent; }
#workspaces button.active { color: #$AC; }
#workspaces button:hover { background: transparent; color: #$FG; }
#cpu, #pulseaudio, #bluetooth, #network, #battery { padding: 0 8px; }
#battery.warning { color: #e0af68; }
#battery.critical { color: #$RED; }
EOF

# ---------------------------------------------------------------- mako / fuzzel
say "Writing mako + fuzzel"
mkdir -p "$CFG/mako" "$CFG/fuzzel"
cat > "$CFG/mako/config" <<EOF
background-color=#$BG
text-color=#$FG
border-color=#$AC
border-size=2
border-radius=8
font=JetBrainsMono Nerd Font 11
padding=12
margin=10
default-timeout=5000
anchor=top-right
EOF

cat > "$CFG/fuzzel/fuzzel.ini" <<EOF
[main]
font=JetBrainsMono Nerd Font:size=13
prompt="> "
width=40
lines=10
horizontal-pad=20
vertical-pad=12
inner-pad=8
terminal=alacritty -e
launch-prefix=uwsm app --

[colors]
background=${BG}f2
text=${FG}ff
prompt=${AC}ff
input=${FG}ff
match=${AC}ff
selection=${AC}33
selection-text=${FG}ff
selection-match=${AC}ff
border=${AC}ff

[border]
width=2
radius=8
EOF

# ---------------------------------------------------------------- terminal
say "Writing terminal + shell config"
mkdir -p "$CFG/alacritty"
cat > "$CFG/alacritty/alacritty.toml" <<EOF
[window]
padding = { x = 14, y = 14 }
decorations = "None"

[font]
normal = { family = "JetBrainsMono Nerd Font", style = "Regular" }
size = 12

[colors.primary]
background = "#$BG"
foreground = "#$FG"

[colors.normal]
black   = "#15161e"
red     = "#$RED"
green   = "#$GREEN"
yellow  = "#e0af68"
blue    = "#$AC"
magenta = "#bb9af7"
cyan    = "#7dcfff"
white   = "#a9b1d6"

[colors.bright]
black   = "#$DIM"
red     = "#$RED"
green   = "#$GREEN"
yellow  = "#e0af68"
blue    = "#$AC"
magenta = "#bb9af7"
cyan    = "#7dcfff"
white   = "#$FG"
EOF

cat > "$CFG/starship.toml" <<'EOF'
add_newline = false
format = "$directory$git_branch$git_status$character"

[character]
success_symbol = "[❯](bold blue)"
error_symbol = "[❯](bold red)"
EOF

if ! grep -qF ">>> cachy-omarchy >>>" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" <<'EOF'

# >>> cachy-omarchy >>>
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim
if [[ $- == *i* ]]; then
  eval "$(starship init bash)"
  eval "$(zoxide init bash --cmd cd)"
  eval "$(mise activate bash)"
  eval "$(fzf --bash)"
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -l --icons --group-directories-first'
  alias la='eza -la --icons --group-directories-first'
  alias cat='bat --paging=never'
  alias v='nvim'
  alias lg='lazygit'
  alias ld='lazydocker'
  alias ff='fastfetch'
fi
# <<< cachy-omarchy <<<
EOF
fi

# login shells (TTY) should also read .bashrc
grep -q 'bashrc' "$HOME/.bash_profile" 2>/dev/null \
  || echo '[[ -f ~/.bashrc ]] && . ~/.bashrc' >> "$HOME/.bash_profile"

# LazyVim (Omarchy's default Neovim setup)
if [[ ! -d "$CFG/nvim" ]]; then
  git clone --depth 1 https://github.com/LazyVim/starter "$CFG/nvim" && rm -rf "$CFG/nvim/.git"
fi

# ---------------------------------------------------------------- GTK / defaults
say "GTK dark theme + default apps"
mkdir -p "$CFG/gtk-3.0" "$CFG/gtk-4.0"
cat > "$CFG/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Noto Sans 11
EOF
cat > "$CFG/gtk-4.0/settings.ini" <<'EOF'
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
gtk-font-name=Noto Sans 11
EOF

echo '--ozone-platform-hint=auto' > "$CFG/chromium-flags.conf"

xdg-mime default chromium.desktop x-scheme-handler/http x-scheme-handler/https text/html
xdg-mime default org.gnome.Nautilus.desktop inode/directory
xdg-mime default org.gnome.Evince.desktop application/pdf
xdg-mime default imv.desktop image/png image/jpeg image/gif image/webp
xdg-mime default mpv.desktop video/mp4 video/x-matroska video/webm

# ---------------------------------------------------------------- helper scripts
say "Writing helper scripts"
cat > "$HOME/.local/bin/power-menu" <<'EOF'
#!/usr/bin/env bash
choice=$(printf 'Lock\nLogout\nSuspend\nReboot\nShutdown' | fuzzel --dmenu --prompt "System > ")
case "$choice" in
  Lock)     pidof hyprlock || hyprlock ;;
  Logout)   uwsm stop ;;
  Suspend)  systemctl suspend ;;
  Reboot)   systemctl reboot ;;
  Shutdown) systemctl poweroff ;;
esac
EOF

cat > "$HOME/.local/bin/theme-switch" <<'EOF'
#!/usr/bin/env bash
# SUPER+K - recolors Waybar, mako, fuzzel, Alacritty, hyprlock, Hyprland borders, wallpaper
C="$HOME/.config"
STATE="$C/cachy-omarchy/theme"

themes="tokyo-night 1a1b26 c0caf5 7aa2f7
catppuccin 1e1e2e cdd6f4 89b4fa
gruvbox 282828 ebdbb2 d79921
nord 2e3440 d8dee9 88c0d0
rose-pine 191724 e0def4 c4a7e7
everforest 2d353b d3c6aa a7c080"

pick=$(cut -d' ' -f1 <<<"$themes" | fuzzel --dmenu --prompt "Theme > ")
[[ -z "$pick" ]] && exit 0
read -r _ BG FG AC <<<"$(grep "^$pick " <<<"$themes")"
read -r OLD_BG OLD_FG OLD_AC < "$STATE"

for f in "$C/waybar/style.css" "$C/mako/config" "$C/fuzzel/fuzzel.ini" \
         "$C/alacritty/alacritty.toml" "$C/hypr/hyprlock.conf" "$C/hypr/hyprland.lua"; do
  sed -i "s/$OLD_BG/$BG/gI; s/$OLD_FG/$FG/gI; s/$OLD_AC/$AC/gI" "$f"
done
echo "$BG $FG $AC" > "$STATE"

mkwall "$BG"
pkill hyprpaper; setsid uwsm app -- hyprpaper >/dev/null 2>&1 &
pkill -SIGUSR2 waybar
makoctl reload
hyprctl reload
notify-send "Theme" "Switched to $pick"
EOF
chmod +x "$HOME/.local/bin/power-menu" "$HOME/.local/bin/theme-switch"

# PATH for the graphical session (uwsm reads this file)
mkdir -p "$CFG/uwsm"
grep -qs '.local/bin' "$CFG/uwsm/env" \
  || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$CFG/uwsm/env"

# ---------------------------------------------------------------- SDDM
say "Configuring SDDM (login screen)"
sudo systemctl enable --force sddm.service

# Make sure a uwsm-managed Hyprland session exists
if ! compgen -G "/usr/share/wayland-sessions/hyprland-uwsm*.desktop" >/dev/null; then
  warn "hyprland-uwsm.desktop missing - creating it"
  sudo tee /usr/share/wayland-sessions/hyprland-uwsm.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=Hyprland (uwsm-managed)
Comment=Hyprland compositor managed by UWSM
Exec=uwsm start -e -D Hyprland hyprland.desktop
Type=Application
DesktopNames=Hyprland
EOF
fi

sudo mkdir -p /etc/sddm.conf.d
{
  echo "[General]"
  echo "Numlock=on"
  if (( AUTOLOGIN )); then
    echo
    echo "[Autologin]"
    echo "User=$USER"
    echo "Session=hyprland-uwsm"
  fi
} | sudo tee /etc/sddm.conf.d/10-cachy-omarchy.conf >/dev/null

# ---------------------------------------------------------------- done
say "Done!"
if ((${#FAILED[@]})); then
  warn "These packages could not be installed: ${FAILED[*]}"
  warn "Install them manually later (check the name with: $AUR -Ss <name>)"
fi

cat <<EOF

Next steps
  1. Reboot. At the SDDM login screen pick the session
     "Hyprland (uwsm-managed)"$( ((AUTOLOGIN)) && echo " (auto-login is ON)").
  2. If something looks off after login, run:   hyprctl configerrors
  3. Keys:  SUPER+Space launcher      SUPER+Return terminal    SUPER+B browser
            SUPER+F files             SUPER+W close window     SUPER+Escape power menu
            SUPER+K switch theme      SUPER+L lock             SUPER+1..0 workspaces
            SUPER+CTRL+W/B/A  wifi / bluetooth / audio
  4. Wallpaper: put any image at ~/.config/hypr/wall.png
  5. Old configs: $BACKUP
  6. Log out/in once (a reboot does it) so the 'docker' group applies.
EOF

if [[ -t 0 ]]; then
  read -rp "Reboot now? [y/N]: " r
  [[ $r =~ ^[Yy] ]] && sudo reboot
fi
