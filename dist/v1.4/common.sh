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
