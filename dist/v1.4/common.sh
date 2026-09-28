#!/bin/bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this
#
# EOS Webcam Utility Fork — helpers shared by install.sh, uninstall.sh and
# diagnose.sh. Sourced, not executed; defines variables and functions only.
#

# The camera manager daemon, its loading-screen images and generate-images.sh
# live in Application Support, NOT in the clone. A LaunchAgent gets no TCC
# (privacy) access to ~/Downloads, ~/Desktop, ~/Documents or iCloud Drive, so a
# daemon run from a clone in one of those crash-loops with exit 126.
EOSWC_RUNTIME_DIR="$HOME/Library/Application Support/EWCService"
EOSWC_AGENT_LABEL="com.eos-camera-manager"
EOSWC_CANON_LABEL="com.canon.usa.EWCService"

# Files the installer copies into the runtime dir. Uninstall removes exactly
# these (plus a user-supplied logo), never the whole dir: it is Canon's own
# config dir too (config.plist / proconfig.plist).
EOSWC_RUNTIME_FILES="eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg"
# generate-images.sh looks for either of these next to itself.
EOSWC_LOGO_FILES="logo.png logo.svg"

# True if launchd has a live process for the job. A label shows up in
# `launchctl list` even while its job is failing to start (PID column "-"),
# so mere presence is not enough. Columns: PID, last exit status, label.
eoswc_job_running() {
    launchctl list 2>/dev/null | awk -v label="$1" '
        $3 == label && $1 != "-" { found = 1 }
        END { exit !found }'
}

# Print the daemon path a camera-manager LaunchAgent plist runs, if any.
eoswc_agent_daemon_path() {
    [ -f "$1" ] || return 0
    sed -n 's:.*<string>\(.*eos-camera-manager\.sh\)</string>.*:\1:p' "$1" | head -1
}

# Remove the daemon copy (and its images) that older installers put in the
# clone. Only the known file names are removed, never the dir itself, and
# never the current runtime dir. A logo.png/logo.svg is left in place.
eoswc_remove_legacy_runtime() {
    local dir="$1" f
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    [ "$dir" -ef "$EOSWC_RUNTIME_DIR" ] && return 0
    for f in $EOSWC_RUNTIME_FILES; do
        if [ -f "$dir/$f" ]; then
            rm -f "$dir/$f" && echo "  Removed old $dir/$f"
        fi
    done
}

EOSWC_REAL_PLUGIN_DIR="/Library/CoreMediaIO/Plug-Ins/DAL/EOSWebcamUtility.plugin"

# Physical path of $1 (absolute), resolving symlinks in the part that exists.
# The part that doesn't exist yet must be plain names: no ".", "..", or links.
eoswc_physical_path() {
    local p="$1" rest=""
    case "$p" in /*) ;; *) return 1 ;; esac
    case "$p/" in */./*|*/../*) return 1 ;; esac
    p="${p%/}"
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        [ -L "$p" ] && return 1
        rest="/${p##*/}$rest"
        p="${p%/*}"
    done
    p="$(cd "${p:-/}" && pwd -P)" || return 1
    printf '%s%s\n' "${p%/}" "$rest"
}

# Set EOSWC_PLUGIN to the plug-in path the scripts act on: always the real one,
# except that tests/ may point EOSWC_PLUGIN_DIR at a fake plug-in. That hook is
# honoured only inside a test sandbox: EOSWC_TEST_SANDBOX must be a dir the
# test harness created and marked, and EOSWC_PLUGIN_DIR must resolve inside
# it. Anything else is refused, loudly, rather than silently falling back:
# uninstall.sh copies files into this path and code-signs it as root.
eoswc_select_plugin_dir() {
    local sandbox="${EOSWC_TEST_SANDBOX:-}" rsand="" rplug=""
    EOSWC_PLUGIN="$EOSWC_REAL_PLUGIN_DIR"
    [ -n "${EOSWC_PLUGIN_DIR:-}" ] || return 0
    if [ -n "$sandbox" ]; then
        rsand="$(cd "$sandbox" 2>/dev/null && pwd -P)" || rsand=""
    fi
    if [ -z "$rsand" ] || [ "$rsand" = / ] || [ ! -f "$rsand/.eoswc-test-sandbox" ] ||
       [ "$(cat "$rsand/.eoswc-test-sandbox" 2>/dev/null)" != "$rsand" ]; then
        echo "ERROR: EOSWC_PLUGIN_DIR is set ($EOSWC_PLUGIN_DIR), but it is a test-only hook" >&2
        echo "       and this is not a test sandbox. Refusing to run. Unset it:" >&2
        echo "         unset EOSWC_PLUGIN_DIR" >&2
        return 1
    fi
    rplug="$(eoswc_physical_path "$EOSWC_PLUGIN_DIR")" || rplug=""
    case "$rplug" in
        "$rsand"/?*) ;;
        *)
            echo "ERROR: EOSWC_PLUGIN_DIR ($EOSWC_PLUGIN_DIR) is outside the test sandbox" >&2
            echo "       $rsand. Refusing to run." >&2
            return 1 ;;
    esac
    EOSWC_PLUGIN="$rplug"
}

# True if launchd has a live process for the job. A label shows up in
# `launchctl list` even while its job is failing to start (PID column "-"),
# so mere presence is not enough. Columns: PID, last exit status, label.
eoswc_job_running() {
    launchctl list 2>/dev/null | awk -v label="$1" '
        $3 == label && $1 != "-" { found = 1 }
        END { exit !found }'
}

# Print the daemon path a camera-manager LaunchAgent plist runs, if any.
eoswc_agent_daemon_path() {
    [ -f "$1" ] || return 0
    sed -n 's:.*<string>\(.*eos-camera-manager\.sh\)</string>.*:\1:p' "$1" | head -1
}

# Remove the daemon copy (and its images) that older installers put in the
# clone. Only the known file names are removed, never the dir itself, and
# never the current runtime dir. A logo.png/logo.svg is left in place.
eoswc_remove_legacy_runtime() {
    local dir="$1" f
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    [ "$dir" -ef "$EOSWC_RUNTIME_DIR" ] && return 0
    for f in $EOSWC_RUNTIME_FILES; do
        if [ -f "$dir/$f" ]; then
            rm -f "$dir/$f" && echo "  Removed old $dir/$f"
        fi
    done
}
