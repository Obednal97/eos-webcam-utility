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

# Backup dirs, newest first, from every location: Application Support, the
# clone ($1, repo root), and the first v1.4 installer's fixed path.
eoswc_backup_candidates() {
    local clone="$1"
    if [ -d "$EOSWC_V14_CLONE/backups" ] && ! [ "$clone" -ef "$EOSWC_V14_CLONE" ]; then
        ls -dt "$EOSWC_BACKUP_ROOT"/pre-v* "$clone"/backups/pre-v* "$EOSWC_V14_CLONE"/backups/pre-v* 2>/dev/null || true
    else
        ls -dt "$EOSWC_BACKUP_ROOT"/pre-v* "$clone"/backups/pre-v* 2>/dev/null || true
    fi
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

# Print the test sandbox's physical path if EOSWC_TEST_SANDBOX is a dir the
# test harness created and marked; fail otherwise.
eoswc_marked_sandbox() {
    local sandbox="${EOSWC_TEST_SANDBOX:-}" rsand=""
    [ -n "$sandbox" ] || return 1
    rsand="$(cd "$sandbox" 2>/dev/null && pwd -P)" || return 1
    [ -n "$rsand" ] && [ "$rsand" != / ] && [ -f "$rsand/.eoswc-test-sandbox" ] &&
        [ "$(cat "$rsand/.eoswc-test-sandbox" 2>/dev/null)" = "$rsand" ] || return 1
    printf '%s\n' "$rsand"
}

# Refuse (loudly, exit status 1) if test-only hook $1 (a variable name) is set
# outside a marked test sandbox. Never silently falls back to the real value.
eoswc_require_sandbox_for() {
    local name="$1" value
    value="${!name:-}"
    [ -n "$value" ] || return 0
    eoswc_marked_sandbox >/dev/null && return 0
    echo "ERROR: $name is set ($value), but it is a test-only hook" >&2
    echo "       and this is not a test sandbox. Refusing to run. Unset it:" >&2
    echo "         unset $name" >&2
    return 1
}

# Print the path a test-only path hook stands for: $3 (the real path) unless
# hook $1 (a variable name, value $2) is set, in which case it must be inside
# a marked test sandbox and resolve inside it. Fails loudly otherwise.
eoswc_sandboxed_path() {
    local name="$1" value="$2" real="$3" rsand rpath
    if [ -z "$value" ]; then
        printf '%s\n' "$real"
        return 0
    fi
    eoswc_require_sandbox_for "$name" || return 1
    rsand="$(eoswc_marked_sandbox)" || return 1
    rpath="$(eoswc_physical_path "$value")" || rpath=""
    case "$rpath" in
        "$rsand"/?*) ;;
        *)
            echo "ERROR: $name ($value) is outside the test sandbox" >&2
            echo "       $rsand. Refusing to run." >&2
            return 1 ;;
    esac
    printf '%s\n' "$rpath"
}

# Set EOSWC_PLUGIN to the plug-in path the scripts act on: always the real one,
# except that tests/ may point EOSWC_PLUGIN_DIR at a fake plug-in. That hook is
# honoured only inside a test sandbox: EOSWC_TEST_SANDBOX must be a dir the
# test harness created and marked, and EOSWC_PLUGIN_DIR must resolve inside
# it. Anything else is refused, loudly, rather than silently falling back:
# uninstall.sh copies files into this path and code-signs it as root.
eoswc_select_plugin_dir() {
    EOSWC_PLUGIN="$EOSWC_REAL_PLUGIN_DIR"
    local p
    p="$(eoswc_sandboxed_path EOSWC_PLUGIN_DIR "${EOSWC_PLUGIN_DIR:-}" "$EOSWC_REAL_PLUGIN_DIR")" || return 1
    EOSWC_PLUGIN="$p"
}

# Canon's apps folder. Canon's v1.3.16 package puts "EOS Webcam Camera
# Extension Installer.app" (the host app of Canon's Camera Extension) and
# "EOS Webcam Utility Uninstaller.app" here. EOSWC_CANON_APP_DIR is a
# test-only hook, guarded like EOSWC_PLUGIN_DIR.
EOSWC_REAL_CANON_APP_DIR="/Applications/EOS Webcam Utility"
eoswc_select_canon_app_dir() {
    EOSWC_CANON_APPS="$EOSWC_REAL_CANON_APP_DIR"
    local p
    p="$(eoswc_sandboxed_path EOSWC_CANON_APP_DIR "${EOSWC_CANON_APP_DIR:-}" "$EOSWC_REAL_CANON_APP_DIR")" || return 1
    EOSWC_CANON_APPS="$p"
}

# Canon's Camera Extension (a CMIOExtension system extension, signed by Canon,
# team NC5A977249). On macOS 14+ Canon's postinstall asks the user to approve
# it; once approved it shows up as a second "EOS Webcam Utility" camera. The
# fork does not patch it.
EOSWC_CAMEXT_ID="com.canon.cusa.eoswebcam.cameraExtension"
EOSWC_CAMEXT_HOST="EOS Webcam Camera Extension Installer.app"
EOSWC_CANON_UNINSTALLER="EOS Webcam Utility Uninstaller.app"

# Print the Camera Extension's state as systemextensionsctl reports it, e.g.
# "activated enabled" or "activated waiting for user"; "not registered" if it
# isn't listed; "unknown" if systemextensionsctl can't be run. Read-only.
eoswc_camera_extension_state() {
    local out line state
    command -v systemextensionsctl >/dev/null 2>&1 || { echo unknown; return 0; }
    out="$(systemextensionsctl list 2>/dev/null)" || { echo unknown; return 0; }
    line="$(printf '%s\n' "$out" | grep -m1 -F "$EOSWC_CAMEXT_ID")"
    if [ -z "$line" ]; then
        echo "not registered"
        return 0
    fi
    state="$(printf '%s\n' "$line" | sed -n 's/.*\[\([^]]*\)\][[:space:]]*$/\1/p')"
    echo "${state:-registered}"
}

# How to remove Canon's Camera Extension. Printed, never done for the user:
# deactivating a system extension needs the user's own approval, and
# `systemextensionsctl uninstall` only works with SIP disabled. (No "X's "
# possessives: diagnose.sh's name redaction would mangle them.)
eoswc_camera_extension_removal_help() {
    local apps="${EOSWC_CANON_APPS:-$EOSWC_REAL_CANON_APP_DIR}"
    echo "$1To remove the Canon Camera Extension (the fork never does this for you):"
    echo "$1  - The Canon uninstaller removes it along with the rest of the Canon"
    echo "$1    software: open \"$apps/$EOSWC_CANON_UNINSTALLER\"."
    echo "$1  - Or keep the Canon software and turn just the extension off in System"
    echo "$1    Settings > General > Login Items & Extensions > Camera Extensions."
    echo "$1  (\`systemextensionsctl uninstall\` needs SIP disabled; do not do that.)"
}

# Refuse to run as root. The scripts ask for admin rights themselves, for one
# step only; run under sudo, every file they write in your home (daemon,
# LaunchAgent, backups) would be root's, and $HOME may not even be yours.
eoswc_refuse_root() {
    if [ "${EUID:-}" = 0 ] || [ "$(id -u 2>/dev/null)" = 0 ]; then
        echo "ERROR: this must not run as root (EUID 0): run without sudo; you'll be"
        echo "       prompted for your password. Nothing was changed."
        return 1
    fi
}

# Check, before anything is stopped or changed, that every tool the scripts
# need is there and that python3 really runs. On a Mac without the Command
# Line Tools, /usr/bin/python3 is only a shim that pops up an install dialog
# (and fails), so it is not even started unless xcode-select reports a
# developer dir. The admin step runs /usr/bin/python3; this shell runs the
# python3 on PATH; both must work. Extra tool names can be passed as args.
eoswc_require_tools() {
    local t missing=""
    for t in osascript launchctl codesign plutil shasum ditto pkill xcode-select "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        echo "  ERROR: required tool(s) not found:$missing"
        echo "         Nothing was changed."
        return 1
    fi
    if ! xcode-select -p >/dev/null 2>&1; then
        echo "  ERROR: python3 needs Apple's Command Line Tools, which aren't installed."
        echo "         Run 'xcode-select --install', then re-run this. Nothing was changed."
        return 1
    fi
    if ! /usr/bin/python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1 ||
       ! python3 -c 'import sys; sys.exit(0)' >/dev/null 2>&1; then
        echo "  ERROR: python3 is installed but doesn't run. Run 'xcode-select --install'"
        echo "         (or fix the python3 on your PATH), then re-run this. Nothing was changed."
        return 1
    fi
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

# Print one value from a plist (keypath like ProgramArguments.1), if it has it.
eoswc_plist_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

# The fork's first camera manager ran as LaunchAgent com.canon-camera-manager,
# from a canon-camera-manager.sh in the clone (work logs 007 and 008). It
# fights the current daemon over restarting Canon's service, so install and
# uninstall remove it, but only if it really is the fork's: that label, and a
# program path ending in /canon-camera-manager.sh.
EOSWC_LEGACY_LABEL="com.canon-camera-manager"
EOSWC_LEGACY_PLIST="$HOME/Library/LaunchAgents/$EOSWC_LEGACY_LABEL.plist"

# True if plist $1 is the fork's legacy camera manager agent. Prints the
# program it runs.
eoswc_legacy_agent_matches() {
    local plist="$1" key arg
    [ -f "$plist" ] || return 1
    [ "$(eoswc_plist_value "$plist" Label)" = "$EOSWC_LEGACY_LABEL" ] || return 1
    for key in Program ProgramArguments.0 ProgramArguments.1 ProgramArguments.2; do
        arg="$(eoswc_plist_value "$plist" "$key")" || continue
        case "$arg" in
            /*/canon-camera-manager.sh)
                printf '%s\n' "$arg"
                return 0 ;;
        esac
    done
    return 1
}

# Stop and remove the legacy agent (bootout first, then the plist) and the
# launchd stdout/stderr logs it wrote to ~/Library/Logs. A plist with that
# name that doesn't match is left alone, with a warning.
eoswc_remove_legacy_agent() {
    local plist="$EOSWC_LEGACY_PLIST" logs="$HOME/Library/Logs" f rest out="" err=""
    [ -e "$plist" ] || return 0
    if ! eoswc_legacy_agent_matches "$plist" >/dev/null; then
        echo "  WARNING: left $plist alone: it doesn't run the fork's old"
        echo "           canon-camera-manager.sh, so it isn't the fork's to remove."
        return 0
    fi
    out="$(eoswc_plist_value "$plist" StandardOutPath)" || out=""
    err="$(eoswc_plist_value "$plist" StandardErrorPath)" || err=""
    launchctl bootout "gui/$(id -u)/$EOSWC_LEGACY_LABEL" 2>/dev/null || true
    rm -f "$plist"
    echo "  Removed the old camera manager LaunchAgent ($EOSWC_LEGACY_LABEL)"
    for f in "$out" "$err" "$logs/canon-camera-manager-stdout.log" "$logs/canon-camera-manager-stderr.log"; do
        # Only log files directly in ~/Library/Logs with the old daemon's name.
        rest="${f#"$logs/"}"
        [ "$rest" != "$f" ] || continue
        case "$rest" in
            */*) continue ;;
            canon-camera-manager*.log) ;;
            *) continue ;;
        esac
        if [ -f "$f" ] && [ ! -L "$f" ]; then
            rm -f "$f" && echo "  Removed $f"
        fi
    done
    return 0
}
