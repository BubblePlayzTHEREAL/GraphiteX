#!/usr/bin/env bash
# =============================================================
# install-calcos.sh
# One-line CalcOS installer for Linux and Windows shells that can run bash.
#
# This script:
#   - downloads adb if it is missing
#   - downloads the CalcOS APK from a hosted URL or uses a local signed build
#   - installs CalcOS through adb
#   - sets CalcOS as the home activity when possible
#   - attempts device-owner provisioning when possible
#   - disables common stock apps and launcher packages
#
# Usage examples:
#   CALCOS_BASE_URL=https://example.com/calcos bash install-calcos.sh
#   CALCOS_APK_URL=https://example.com/calcos/calcos-launcher.apk bash install-calcos.sh
#   bash install-calcos.sh --apk-url https://example.com/calcos-launcher.apk
# =============================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

CALCOS_PACKAGE="org.calcos.launcher"
CALCOS_ACTIVITY="org.calcos.launcher/.KioskActivity"
CALCOS_ADMIN="org.calcos.launcher/.AdminReceiver"
CALCOS_DEFAULT_APK_URL="${CALCOS_BASE_URL:-}"
if [ -n "${CALCOS_DEFAULT_APK_URL}" ]; then
    CALCOS_DEFAULT_APK_URL="${CALCOS_DEFAULT_APK_URL%/}/calcos-launcher.apk"
fi

TMP_DIR="$(mktemp -d)"
ADB_DIR=""
APK_FILE=""
APK_URL="${CALCOS_APK_URL:-${CALCOS_DEFAULT_APK_URL:-}}"
ADB_SERIAL="${ADB_SERIAL:-}"
SKIP_DISABLE="${CALCOS_SKIP_DISABLE:-0}"
ADB_BIN=""

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

download_file() {
    local url="$1"
    local dest="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 1 -o "$dest" "$url"
        return 0
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
        return 0
    fi

    die "Neither curl nor wget is available"
}

extract_zip() {
    local zip_file="$1"
    local dest_dir="$2"

    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip_file" -d "$dest_dir"
        return 0
    fi

    if command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force -Path '$(printf "%s" "$zip_file" | sed "s/'/''/g")' -DestinationPath '$(printf "%s" "$dest_dir" | sed "s/'/''/g")'"
        return 0
    fi

    die "No unzip tool found"
}

download_adb() {
    local os_name="$1"
    local platform_zip=""
    local platform_dir="$TMP_DIR/platform-tools"

    mkdir -p "$platform_dir"

    case "$os_name" in
        Linux)
            platform_zip="$TMP_DIR/platform-tools-linux.zip"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            platform_zip="$TMP_DIR/platform-tools-windows.zip"
            ;;
        *)
            platform_zip="$TMP_DIR/platform-tools.zip"
            ;;
    esac

    log "Downloading Android platform-tools..."
    if [[ "$os_name" == MINGW* || "$os_name" == MSYS* || "$os_name" == CYGWIN* ]]; then
        download_file "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" "$platform_zip"
    else
        download_file "https://dl.google.com/android/repository/platform-tools-latest-linux.zip" "$platform_zip"
    fi

    extract_zip "$platform_zip" "$TMP_DIR"

    if [ -x "$TMP_DIR/platform-tools/adb" ]; then
        ADB_DIR="$TMP_DIR/platform-tools"
    elif [ -x "$TMP_DIR/platform-tools/adb.exe" ]; then
        ADB_DIR="$TMP_DIR/platform-tools"
    else
        die "adb was not found after extracting platform-tools"
    fi
}

ensure_adb() {
    if command -v adb >/dev/null 2>&1; then
        ADB_BIN="$(command -v adb)"
        return 0
    fi

    download_adb "$(uname -s)"

    if [ -x "$ADB_DIR/adb" ]; then
        ADB_BIN="$ADB_DIR/adb"
    elif [ -x "$ADB_DIR/adb.exe" ]; then
        ADB_BIN="$ADB_DIR/adb.exe"
    else
        die "Could not locate adb binary"
    fi
}

adb_cmd() {
    if [ -n "$ADB_SERIAL" ]; then
        "$ADB_BIN" -s "$ADB_SERIAL" "$@"
    else
        "$ADB_BIN" "$@"
    fi
}

resolve_local_apk() {
    local candidate=""

    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/calcos-launcher/app/build/outputs/apk/release/app-release.apk" ]; then
        candidate="$SCRIPT_DIR/calcos-launcher/app/build/outputs/apk/release/app-release.apk"
    elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/calcos-launcher/app/build/outputs/apk/release/app-release-unsigned.apk" ]; then
        candidate="$SCRIPT_DIR/calcos-launcher/app/build/outputs/apk/release/app-release-unsigned.apk"
    fi

    if [ -n "$candidate" ]; then
        printf '%s\n' "$candidate"
    fi
}

collect_device() {
    local device_line=""

    if [ -n "$ADB_SERIAL" ]; then
        printf '%s\n' "$ADB_SERIAL"
        return 0
    fi

    device_line="$($ADB_BIN devices | awk 'NR>1 && $2 == "device" { print $1; exit }')"
    if [ -z "$device_line" ]; then
        die "No device found. Connect a device with USB debugging enabled."
    fi

    printf '%s\n' "$device_line"
}

disable_packages() {
    local pkg
    local packages=(
        com.android.launcher3
        com.android.launcher3.quickstep
        com.google.android.googlequicksearchbox
        com.android.chrome
        com.google.android.apps.chrome
        com.google.android.youtube
        com.google.android.apps.youtube
        com.google.android.apps.maps
        com.google.android.apps.photos
        com.google.android.gm
        com.google.android.calendar
        com.google.android.contacts
        com.google.android.dialer
        com.google.android.apps.messaging
        com.android.camera2
        com.android.camera
        com.android.gallery3d
        com.android.music
        com.android.email
        com.android.browser
        com.android.mms
        com.android.contacts
        com.android.dialer
        com.android.phone
        com.android.messaging
        com.android.documentsui
        com.android.providers.downloads.ui
        com.android.providers.downloads
        com.android.vending
        com.google.android.gms
        com.google.android.gsf
        com.google.android.apps.tachyon
        com.google.android.apps.assistant
        org.lineageos.jelly
        org.lineageos.eleven
        org.lineageos.etar
        org.lineageos.recorder
        org.lineageos.snap
        org.lineageos.calendar
        org.lineageos.music
        Trebuchet
        Launcher3
        Launcher3QuickStep
        Camera2
        Gallery2
        Music
        Calendar
        Email
        Contacts
        ContactsProvider
        Dialer
        Phone
        Messaging
        Mms
        Browser
        Browser2
        Chrome
        GoogleChrome
        Maps
        YouTube
        PlayStore
        GmsCore
        GoogleServicesFramework
        Phonesky
        Velvet
        Files
        DocumentsUI
        DownloadProvider
        DownloadProviderUi
    )

    for pkg in "${packages[@]}"; do
        "$ADB_BIN" shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1 || true
        "$ADB_BIN" shell cmd package disable-user --user 0 "$pkg" >/dev/null 2>&1 || true
    done
}

main() {
    local arg
    local apk_source=""
    local device=""

    while [ "$#" -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --apk-url)
                APK_URL="${2:-}"
                shift 2
                ;;
            --base-url)
                CALCOS_DEFAULT_APK_URL="${2:-}"
                if [ -n "$CALCOS_DEFAULT_APK_URL" ]; then
                    CALCOS_DEFAULT_APK_URL="${CALCOS_DEFAULT_APK_URL%/}/calcos-launcher.apk"
                fi
                if [ -z "${APK_URL:-}" ]; then
                    APK_URL="$CALCOS_DEFAULT_APK_URL"
                fi
                shift 2
                ;;
            --device)
                ADB_SERIAL="${2:-}"
                shift 2
                ;;
            --skip-disable)
                SKIP_DISABLE=1
                shift
                ;;
            -h|--help)
                cat <<'EOF'
Install CalcOS on a connected Android device.

Options:
  --apk-url URL      Use this APK URL instead of the default base URL
  --base-url URL     Use URL/calcos-launcher.apk as the APK source
  --device SERIAL    Target a specific adb device serial
  --skip-disable     Skip the app-disable step
EOF
                return 0
                ;;
            *)
                die "Unknown option: $arg"
                ;;
        esac
    done

    ensure_adb
    device="$(collect_device)"

    log "Using device: $device"

    if [ -z "$APK_URL" ]; then
        apk_source="$(resolve_local_apk || true)"
        if [ -n "$apk_source" ]; then
            case "$apk_source" in
                *app-release-unsigned.apk)
                    die "Found only the unsigned Gradle output. Host a signed APK and set CALCOS_APK_URL or CALCOS_BASE_URL."
                    ;;
            esac
            APK_FILE="$apk_source"
            log "Using local APK: $APK_FILE"
        else
            die "No APK URL provided. Set CALCOS_BASE_URL or CALCOS_APK_URL, or run from a checkout with a release APK at rom/calcos-launcher/app/build/outputs/apk/release/."
        fi
    else
        APK_FILE="$TMP_DIR/calcos-launcher.apk"
        log "Downloading APK..."
        download_file "$APK_URL" "$APK_FILE"
    fi

    log "Installing CalcOS Launcher..."
    adb_cmd wait-for-device
    adb_cmd install -r -g "$APK_FILE"

    log "Setting default home activity..."
    adb_cmd shell pm set-home-activity "$CALCOS_ACTIVITY" >/dev/null 2>&1 || true
    adb_cmd shell cmd package set-home-activity "$CALCOS_ACTIVITY" >/dev/null 2>&1 || true

    log "Applying kiosk settings..."
    adb_cmd shell settings put global policy_control 'immersive.full=*' || true
    adb_cmd shell settings put system screen_off_timeout 2147483647 || true
    adb_cmd shell settings put secure lockscreen.disabled 1 || true
    adb_cmd shell settings put system screen_brightness 255 || true
    adb_cmd shell settings put system screen_brightness_mode 0 || true

    log "Attempting device-owner provisioning..."
    adb_cmd shell dpm set-device-owner "$CALCOS_ADMIN" >/dev/null 2>&1 || \
        warn "Could not set device owner. Remove accounts first, or rerun on a fresh device."

    if [ "$SKIP_DISABLE" != "1" ]; then
        log "Disabling common stock apps..."
        disable_packages
    fi

    log "Launching CalcOS..."
    adb_cmd shell am start -n "$CALCOS_ACTIVITY" --activity-clear-top --activity-single-top >/dev/null 2>&1 || true

    log "Done."
    log "Undo with: adb shell dpm remove-active-admin $CALCOS_ADMIN"
    log "Undo with: adb shell pm uninstall $CALCOS_PACKAGE"
}

main "$@"
