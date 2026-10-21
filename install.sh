#!/usr/bin/env bash
# Deadband (Qt) — user-local installer for Arch/KDE and other Linux.
#
#   git clone <repo> && cd "GameSir Linux" && ./install.sh
#
# Installs into your home (~/.local), so the only step that needs sudo is the
# one-time udev rule that lets you open the controller without root. Re-runnable.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="deadband"
# Pre-rename install id. The app used to be "gamesir-cyclone2"; leaving that
# behind would give you a second launcher entry pointing at gamesir_qt.py,
# which no longer exists. Cleaned up below. (Settings are carried over
# separately, on first run — see _migrate_settings in deadband.py.)
OLD_APP_ID="gamesir-cyclone2"
BIN="$HOME/.local/bin"
DESKTOP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor"

echo "==> Installing Deadband from: $REPO"
echo "    This installs into your home (~/.local) and never needs root for the"
echo "    app itself. The only step that uses sudo is the optional udev rule,"
echo "    and it asks first."

# Ask a yes/no question. Defaults to "no" if there's no terminal (so the script
# never silently runs a privileged command in a non-interactive context).
confirm() {
  local ans
  if [ ! -t 0 ]; then
    echo "    (no terminal attached — assuming \"no\")"
    return 1
  fi
  read -rp "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == y* ]]
}

# 1. dependencies -----------------------------------------------------------
# Which Python runs the app. Everywhere but SteamOS that's the system python3.
PY=python3
# SteamOS needs a different route entirely, for three reasons that each broke
# an earlier version of this script:
#   * pacman is there but must not be used: python-hidapi conflicts with
#     python-hid, which jupiter-hw-support (the Deck's own hardware support)
#     depends on, and the read-only rootfs reverts on update anyway (#13).
#   * there is no `pip` command (#19).
#   * there is no compiler or headers, so hidapi can't be built from source.
# So on SteamOS the app runs from a private virtual environment in ~/.local
# (survives updates, touches no system package). It bootstraps its own pip from
# Python's bundled ensurepip, installs only PySide6 into it, and sees the
# system's python-hid through --system-site-packages; hidcompat.py adapts that
# library, so no hidapi build is needed at all.
_STEAMOS=0
if grep -qs '^ID=steamos' /etc/os-release || command -v steamos-readonly >/dev/null; then
  _STEAMOS=1
fi
VENV="$HOME/.local/share/$APP_ID/venv"
if [ "$_STEAMOS" = 1 ] && [ -x "$VENV/bin/python" ]; then
  PY="$VENV/bin/python"          # re-run: reuse the environment we made before
fi

check_deps() {
  missing=()
  command -v python3 >/dev/null || missing+=("python")
  "$PY" -c 'import PySide6' 2>/dev/null || missing+=("pyside6")
  "$PY" -c 'import hid'     2>/dev/null || missing+=("python-hidapi")
  "$PY" -c 'import ctypes.util; assert ctypes.util.find_library("usb-1.0")' \
    2>/dev/null || missing+=("libusb")
}
check_deps

if [ ${#missing[@]} -ne 0 ]; then
  echo
  echo "==> Missing dependencies: ${missing[*]}"
  if [ "$_STEAMOS" = 1 ]; then
    echo "    Detected SteamOS. System packages can't be changed safely here, so"
    echo "    Deadband gets its own private Python environment in your home folder:"
    echo "        $VENV"
    echo "    It survives SteamOS updates and touches no system package. Only"
    echo "    PySide6 (the UI toolkit, roughly a 200 MB download) goes into it;"
    echo "    the controller library SteamOS already ships is reused."
    if confirm "    Set that up now?"; then
      mkdir -p "$(dirname "$VENV")"
      if ! python3 -m venv --system-site-packages "$VENV"; then
        # ensurepip missing from this Python: make the environment without pip,
        # then fetch pip's official bootstrap script into it.
        echo "    Python's bundled pip isn't available; fetching pip's official"
        echo "    installer (bootstrap.pypa.io) into the private environment instead."
        rm -rf "$VENV"
        python3 -m venv --system-site-packages --without-pip "$VENV"
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$VENV/bin/python"
      fi
      "$VENV/bin/python" -m pip install --upgrade PySide6
      PY="$VENV/bin/python"
      check_deps
      if [ ${#missing[@]} -ne 0 ]; then
        echo "    !! Still missing: ${missing[*]}"
        echo "    Please open an issue with that line and the output above."
        exit 1
      fi
      echo "    Done — dependencies are in place."
    else
      echo "    Skipped. Re-run this script when you're ready."; exit 1
    fi
  elif command -v pacman >/dev/null; then
    echo "    These can be installed with (uses sudo):"
    echo "        sudo pacman -S --needed python pyside6 python-hidapi libusb"
    if confirm "    Run that now?"; then
      sudo pacman -S --needed python pyside6 python-hidapi libusb
    else
      echo "    Skipped. Install them yourself, then re-run this script."; exit 1
    fi
  else
    echo "   Install the system libusb-1.0 runtime plus PySide6 and hidapi for"
    echo "   Python 3, then re-run this script:"
    echo "       pip install --user PySide6"
    echo "       HIDAPI_WITH_HIDRAW=1 pip install --user --no-binary :all: hidapi"
    echo "   (The HIDAPI_WITH_HIDRAW=1 matters: pip's source build DEFAULTS to the"
    echo "    libusb backend, which cannot open the controller. Building needs gcc,"
    echo "    python3-devel and libudev headers — Fedora/Bazzite: systemd-devel.)"
    echo "   A distro package of python-hid (pyhidapi) works too, instead of hidapi."
    exit 1
  fi
fi

# 1b. hidapi backend check --------------------------------------------------
# `import hid` succeeding is not enough: a source-built pip hidapi DEFAULTS to
# the libusb backend, which cannot open /dev/hidraw — the app then finds the
# controller but every open fails. Catch that here, not at first run.
backend="$("$PY" -c "import sys; sys.path.insert(0, '$REPO')
from doctor import _hidapi_backend; print(_hidapi_backend())" 2>/dev/null || echo unknown)"
case "$backend" in
  libusb*)
    echo
    echo "==> WARNING: your Python hidapi uses the libusb backend ($backend)."
    echo "    It cannot open hidraw devices, so Deadband will find your controller"
    echo "    but fail to talk to it. Rebuild hidapi with the hidraw backend:"
    echo "        HIDAPI_WITH_HIDRAW=1 pip install --user --force-reinstall \\"
    echo "            --no-cache-dir --no-binary :all: hidapi"
    echo "    (--no-cache-dir matters: pip otherwise reuses the old libusb build."
    echo "     Needs gcc, python3-devel, libudev headers — Fedora/Bazzite:"
    echo "     rpm-ostree install systemd-devel, then reboot.)"
    if confirm "    Try that rebuild now?"; then
      HIDAPI_WITH_HIDRAW=1 pip install --user --force-reinstall \
        --no-cache-dir --no-binary :all: hidapi
      backend="$("$PY" -c "import sys; sys.path.insert(0, '$REPO')
from doctor import _hidapi_backend; print(_hidapi_backend())" 2>/dev/null || echo unknown)"
      case "$backend" in
        hidraw*) echo "    Rebuilt OK — hidraw backend active." ;;
        *) echo "    Still not hidraw ($backend) — run ./deadband --doctor after"
           echo "    installing the build prerequisites, and re-run this script." ;;
      esac
    else
      echo "    Continuing anyway — the app's Diagnostics window shows this too."
    fi
    ;;
esac

# 2. udev rule (one-time sudo, optional) -----------------------------------
RULE_OK=1
if [ ! -f /etc/udev/rules.d/70-gamesir.rules ] || \
   ! cmp -s "$REPO/70-gamesir.rules" /etc/udev/rules.d/70-gamesir.rules; then
  echo
  echo "==> Controller access (udev rule)"
  echo "    To open the controller without running the app as root, one file is"
  echo "    copied into /etc/udev/rules.d/ and the rules are reloaded. The exact"
  echo "    commands, which need sudo, are:"
  echo "        sudo cp \"$REPO/70-gamesir.rules\" /etc/udev/rules.d/"
  echo "        sudo udevadm control --reload-rules && sudo udevadm trigger"
  if confirm "    Run these now?"; then
    if sudo cp "$REPO/70-gamesir.rules" /etc/udev/rules.d/ \
       && sudo udevadm control --reload-rules && sudo udevadm trigger; then
      echo "    Installed. Unplug and replug the controller once before use."
    else
      RULE_OK=0
      echo "    !! udev step failed — continuing without it (see the note below)."
    fi
  else
    RULE_OK=0
    echo "    Skipped. The app still installs and launches from your menu, but it"
    echo "    can't reach the controller until the rule is in place. You can:"
    echo "      • re-run ./install.sh and accept this step,"
    echo "      • run the two commands above yourself later, or"
    echo "      • launch it with sudo (not recommended)."
  fi
else
  echo "==> current udev rule already installed"
fi

# 3. launcher ---------------------------------------------------------------
mkdir -p "$BIN"
cat > "$BIN/$APP_ID" <<EOF
#!/usr/bin/env bash
exec "$PY" "$REPO/deadband.py" "\$@"
EOF
chmod +x "$BIN/$APP_ID"

# Shell completions ---------------------------------------------------------
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
install -Dm644 "$REPO/completions/bash/deadband" \
  "$DATA_HOME/bash-completion/completions/deadband"
install -Dm644 "$REPO/completions/zsh/_deadband" \
  "$DATA_HOME/zsh/site-functions/_deadband"
install -Dm644 "$REPO/completions/fish/deadband.fish" \
  "$CONFIG_HOME/fish/completions/deadband.fish"

# 4. icons ------------------------------------------------------------------
install -Dm644 "$REPO/assets/icon.png"     "$ICON_DIR/256x256/apps/$APP_ID.png"
install -Dm644 "$REPO/assets/icon-128.png" "$ICON_DIR/128x128/apps/$APP_ID.png"
install -Dm644 "$REPO/assets/icon-64.png"  "$ICON_DIR/64x64/apps/$APP_ID.png"
install -Dm644 "$REPO/assets/icon-48.png"  "$ICON_DIR/48x48/apps/$APP_ID.png"

# 5. desktop entry ----------------------------------------------------------
mkdir -p "$DESKTOP_DIR"
cat > "$DESKTOP_DIR/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Deadband
GenericName=Controller Configuration
Comment=Configure game controller lighting, sticks, triggers and buttons
Exec=$BIN/$APP_ID
Icon=$APP_ID
Terminal=false
Categories=Settings;HardwareSettings;
Keywords=controller;gamepad;joystick;rgb;deadzone;gamesir;
EOF

# 6. remove the pre-rename install ------------------------------------------
if [ "$OLD_APP_ID" != "$APP_ID" ]; then
  removed=0
  for f in "$BIN/$OLD_APP_ID" "$DESKTOP_DIR/$OLD_APP_ID.desktop"; do
    [ -e "$f" ] && { rm -f "$f"; removed=1; }
  done
  for sz in 256x256 128x128 64x64 48x48; do
    f="$ICON_DIR/$sz/apps/$OLD_APP_ID.png"
    [ -e "$f" ] && { rm -f "$f"; removed=1; }
  done
  [ "$removed" = 1 ] && echo "==> Removed the old '$OLD_APP_ID' install (renamed to $APP_ID)."
fi

update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
gtk-update-icon-cache -f "$ICON_DIR" 2>/dev/null || true

echo
echo "==> Done. Find 'Deadband' in your app launcher, or run: $APP_ID"
echo "    Bash and Fish completions are installed in your user directories."
echo "    For Zsh, add this to ~/.zshrc if your completion path doesn't include it:"
echo "        fpath=(\"$DATA_HOME/zsh/site-functions\" \$fpath)"
echo "        autoload -Uz compinit && compinit"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "    (Note: add ~/.local/bin to your PATH to use the '$APP_ID' command.)" ;;
esac
echo "    If the app says your controller is in the wrong mode, it tells you how to"
echo "    switch it for that model (e.g. Cyclone 2: hold the green button ~2s)."
if [ "$RULE_OK" -ne 1 ]; then
  echo
  echo "    Reminder: the udev rule was not installed, so the app won't see the"
  echo "    controller yet. Re-run ./install.sh (accepting the udev step) to fix."
fi
