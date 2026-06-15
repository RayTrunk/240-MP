#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 240-MP installer for Debian/Ubuntu on x86_64 and arm64
#
# Usage:
#   bash install.sh             # install latest release
#   bash install.sh v1.2.0      # install a specific release tag
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="RayTrunk/240-MP"
INSTALL_DIR="/opt/240mp"
LAUNCHER="/usr/local/bin/240mp"
SYSTEMD_SERVICE="/etc/systemd/system/240mp.service"

# ── Detect architecture ────────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        LINUX_ARCH="x86_64"
        QML_LIB_PATH="/usr/lib/x86_64-linux-gnu/qt6/qml"
        ;;
    aarch64)
        LINUX_ARCH="arm64"
        QML_LIB_PATH="/usr/lib/aarch64-linux-gnu/qt6/qml"
        ;;
    *)
        echo "Error: unsupported architecture: $ARCH"
        echo "Supported: x86_64, aarch64 (arm64)"
        exit 1
        ;;
esac
echo "Detected architecture: $ARCH"

# ── Resolve version ────────────────────────────────────────────────────────────
VERSION="${1:-latest}"
if [ "$VERSION" = "latest" ]; then
    echo "Fetching latest release tag..."
    VERSION=$(curl -fsSL \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])")
fi
echo "Installing 240-MP ${VERSION}"

TARBALL="240-MP-${VERSION}-linux-${LINUX_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARBALL}"

# ── Install runtime dependencies ──────────────────────────────────────────────
echo "Installing runtime dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    libqt6quick6 \
    libqt6qml6 \
    libqt6opengl6 \
    libqt6network6 \
    libqt6svg6 \
    qt6-wayland \
    qml6-module-qtquick \
    qml6-module-qtquick-controls \
    qml6-module-qtquick-window \
    qml6-module-qtquick-effects \
    libsdl2-2.0-0 \
    mpv

# ── udev rule: allow tty group to open /dev/tty0 for VT switching ─────────────
echo 'KERNEL=="tty0", GROUP="tty", MODE="0620"' \
    | sudo tee /etc/udev/rules.d/99-240mp-tty.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger /dev/tty0

# ── Download tarball ───────────────────────────────────────────────────────────
echo "Downloading ${TARBALL}..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL -o "${TMP_DIR}/${TARBALL}" "${DOWNLOAD_URL}"

# ── Extract to install directory ───────────────────────────────────────────────
# Tarball structure: usr/local/bin/240mp + usr/local/share/240mp/...
# We strip the usr/local prefix and place files directly in $INSTALL_DIR.
echo "Extracting to ${INSTALL_DIR}..."
sudo mkdir -p "${INSTALL_DIR}"
sudo tar -xzf "${TMP_DIR}/${TARBALL}" \
    --strip-components=3 \
    -C "${INSTALL_DIR}"

# ── Create launcher ────────────────────────────────────────────────────────────
echo "Creating launcher at ${LAUNCHER}..."
sudo tee "${LAUNCHER}" > /dev/null << LAUNCHER_SCRIPT
#!/usr/bin/env bash
# 240-MP launcher — auto-detects display platform
INSTALL_DIR="/opt/240mp"

if [ -n "\${WAYLAND_DISPLAY:-}" ]; then
    QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-wayland}"
elif [ -n "\${DISPLAY:-}" ]; then
    QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-xcb}"
else
    # No display server — use EGLFS for headless/kiosk mode
    QT_QPA_PLATFORM="\${QT_QPA_PLATFORM:-eglfs}"
    export QT_QPA_EGLFS_ALWAYS_SET_MODE=1
    export QT_QPA_EGLFS_KMS_ATOMIC=1

    # Point Qt EGLFS at the DRM card that has a real display pipeline. Render-
    # only nodes (v3d) have no connector dirs under /sys/class/drm and make Qt
    # fail with "drmModeGetResources failed (Operation not supported)". On
    # Pi3B+/Pi4 the display card happens to be card0 (auto-pick works), but on
    # Pi5 the v3d render node often enumerates first, so we must select the
    # right card explicitly. Prefer a connected connector; fall back to the
    # first card that has any connector at all.
    KMS_CARD=""
    for s in /sys/class/drm/card*-*/status; do
        [ -e "$s" ] || continue
        if [ "$(cat "$s")" = "connected" ]; then
            n=$(basename "$(dirname "$s")"); KMS_CARD="${n%%-*}"; break
        fi
    done
    if [ -z "$KMS_CARD" ]; then
        for d in /sys/class/drm/card*-*; do
            [ -e "$d" ] || continue
            n=$(basename "$d"); KMS_CARD="${n%%-*}"; break
        done
    fi
    if [ -n "$KMS_CARD" ] && [ -e "/dev/dri/$KMS_CARD" ]; then
        KMS_CONF="${XDG_RUNTIME_DIR:-/tmp}/240mp-kms.json"
        printf '{ "device": "/dev/dri/%s" }\n' "$KMS_CARD" > "$KMS_CONF"
        export QT_QPA_EGLFS_KMS_CONFIG="$KMS_CONF"
    fi
fi

export QT_QPA_PLATFORM
export QML2_IMPORT_PATH="${QML_LIB_PATH}"

exec "\${INSTALL_DIR}/bin/240mp" "\$@"
LAUNCHER_SCRIPT

sudo chmod +x "${LAUNCHER}"

# ── Optional: systemd autostart ───────────────────────────────────────────────
echo ""
read -r -p "Install systemd autostart service? [y/N] " REPLY
if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    DEFAULT_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
    read -r -p "Run service as user [default: ${DEFAULT_USER}]: " SERVICE_USER
    SERVICE_USER="${SERVICE_USER:-${DEFAULT_USER}}"

    sudo tee "${SYSTEMD_SERVICE}" > /dev/null << UNIT
[Unit]
Description=240-MP Media Player
After=multi-user.target sound.target

[Service]
Type=simple
User=${SERVICE_USER}
SupplementaryGroups=tty video input
AmbientCapabilities=CAP_SYS_TTY_CONFIG
Environment=QT_QPA_PLATFORM=eglfs
Environment=QT_QPA_EGLFS_ALWAYS_SET_MODE=1
Environment=QT_QPA_EGLFS_KMS_ATOMIC=1
Environment=QML2_IMPORT_PATH=${QML_LIB_PATH}
ExecStart=${LAUNCHER}
Restart=on-failure
RestartSec=5s
ExecStopPost=+systemctl poweroff
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

    sudo systemctl mask getty@tty1.service autovt@.service
    sudo systemctl daemon-reload
    sudo systemctl enable 240mp.service
    echo "Service installed and enabled."
    echo "Start now with: sudo systemctl start 240mp"
fi

echo ""
echo "240-MP ${VERSION} installed successfully on ${ARCH}."
echo "Run: 240mp"
