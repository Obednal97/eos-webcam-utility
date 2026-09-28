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

# Snapshots of Canon's original binaries (and config), one pre-v<version>-<time>
# dir per install. They live in Application Support, not in the clone and not
# in a temp dir: the admin step can write here (TCC does not cover it, see
# above), macOS never purges it the way it purges $TMPDIR, and it survives the
# clone being moved or deleted. Earlier installers kept them in the clone
# under backups/; uninstall.sh still looks there too.
EOSWC_BACKUP_ROOT="$EOSWC_RUNTIME_DIR/backups"

# The very first v1.4 installer assumed the clone was here, wherever it
# really was, and kept its backups under it.
EOSWC_V14_CLONE="$HOME/development/webcam-utility"

# Backup dirs, newest first, from every location: Application Support, each
# clone given (repo roots: the one this script runs from, and the one an
# older install ran its daemon from, see eoswc_old_clone_dir), and the first
# v1.4 installer's fixed path. A clone given twice is searched once.
eoswc_backup_candidates() {
    local c d seen clones=() globs=("$EOSWC_BACKUP_ROOT"/pre-v*)
    for c in "$@" "$EOSWC_V14_CLONE"; do
        [ -n "$c" ] && [ -d "$c/backups" ] || continue
        seen=0
        for d in "${clones[@]+"${clones[@]}"}"; do
            [ "$c" -ef "$d" ] && seen=1
        done
        [ "$seen" = 1 ] && continue
        clones+=("$c")
        globs+=("$c"/backups/pre-v*)
    done
    ls -dt "${globs[@]}" 2>/dev/null || true
}

# The clone an older install (v1.4.1 and before) ran from, going by the
# camera-manager LaunchAgent plist $1: those installers put the daemon at
# <clone>/eos-camera-manager.sh and their backups in <clone>/backups/. Prints
# nothing if the agent runs the daemon from the runtime dir (this layout) or
# the dir is gone. The clone may differ from the one running this script: an
# upgrade from a fresh clone is the usual case.
eoswc_old_clone_dir() {
    local daemon dir
    daemon="$(eoswc_agent_daemon_path "$1")"
    case "$daemon" in /?*/eos-camera-manager.sh) ;; *) return 0 ;; esac
    dir="${daemon%/eos-camera-manager.sh}"
    [ -d "$dir" ] || return 0
    [ "$dir" -ef "$EOSWC_RUNTIME_DIR" ] && return 0
    printf '%s\n' "$dir"
}

# Files a backup dir can hold; the first three are the ones that matter.
EOSWC_BACKUP_FILES="EOSWebcamUtility EOSWebcamService EWCProxy EWCPairingService errorNoDevice.jpg errorBusy.jpg default.jpg config.plist proconfig.plist"

# Copy backup dir $1 (outside Application Support, e.g. an old clone's
# backups/) into EOSWC_BACKUP_ROOT under the same name, so it outlives that
# clone. $2 is patch-binaries.py. The copy is written under a temporary name,
# checked (every file byte-identical to the source, and --check-original),
# and only then given its pre-v* name, so a half-written copy is never taken
# for a backup. The source is only read, never changed or removed. Prints the
# copy's path. If an identical copy is already there, prints that instead.
eoswc_adopt_backup() {
    local src="$1" patcher="$2" name dest tmp f ok=1
    name="$(basename "$src")"
    case "$name" in pre-v*) ;; *) return 1 ;; esac
    dest="$EOSWC_BACKUP_ROOT/$name"
    if [ -e "$dest" ]; then
        for f in $EOSWC_BACKUP_FILES; do
            if [ -f "$src/$f" ]; then cmp -s "$src/$f" "$dest/$f" || ok=0; fi
        done
        if [ "$ok" = 1 ] && python3 "$patcher" --check-original "$dest" >/dev/null 2>&1; then
            printf '%s\n' "$dest"
            return 0
        fi
        dest="$EOSWC_BACKUP_ROOT/$name-copy-$(date +%Y%m%d-%H%M%S)"
        [ ! -e "$dest" ] || return 1
    fi
    mkdir -p "$EOSWC_BACKUP_ROOT" || return 1
    tmp="$(mktemp -d "$EOSWC_BACKUP_ROOT/.copying.XXXXXX")" || return 1
    for f in $EOSWC_BACKUP_FILES; do
        if [ -f "$src/$f" ]; then
            cp -p "$src/$f" "$tmp/$f" && cmp -s "$src/$f" "$tmp/$f" || ok=0
        fi
    done
    if [ "$ok" = 1 ] && python3 "$patcher" --check-original "$tmp" >/dev/null 2>&1 &&
       mv "$tmp" "$dest"; then
        printf '%s\n' "$dest"
        return 0
    fi
    # Only what this function wrote, in the dir it just made.
    for f in $EOSWC_BACKUP_FILES; do rm -f "$tmp/$f"; done
    rmdir "$tmp" 2>/dev/null
    return 1
}

# $1 quoted for a shell command line, e.g. the scripts root runs: 'it'\''s'.
eoswc_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
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
