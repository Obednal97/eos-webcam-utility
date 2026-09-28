#!/bin/bash
# diagnose.sh against a fake home. See helpers.sh.
. "$(dirname "$0")/helpers.sh"

installed_layout() {
    mkdir -p "$RUNTIME"
    local f
    for f in eos-camera-manager.sh generate-images.sh errorNoDevice_connecting.jpg errorNoDevice_disconnected.jpg config.plist; do
        echo x > "$RUNTIME/$f"
    done
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$RUNTIME" > "$AGENT"
}

report() { echo "$HOME/Desktop/eos-webcam-diagnostics.txt"; }

test_reads_the_new_runtime_path() {
    installed_layout
    launchctl_lists "501|0|com.canon.usa.EWCService" "502|0|com.eos-camera-manager" "-|0|com.apple.videosubscriptionsd"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_file "$r"
    assert_contains "$r" "501	0	com.canon.usa.EWCService"
    assert_contains "$r" "----- Camera manager install -----"
    # The username is redacted in the report, so match the path's tail.
    assert_contains "$r" "Library/Application Support/EWCService/eos-camera-manager.sh"
    assert_contains "$r" "LaunchAgent runs: "
    assert_contains "$r" "errorNoDevice_disconnected.jpg"   # runtime dir listing
    assert_lacks "$r" "[WARN] LaunchAgent points at an old install location"
    assert_lacks "$r" "[WARN] that daemon file does not exist"
    assert_lacks "$r" "privacy-protected folder"
    assert_contains "$r" "com.canon.usa.EWCService: RUNNING (PID 501)"
    assert_lacks "$r" "com.apple.videosubscriptionsd"
    assert_contains "$r" "com.eos-camera-manager: RUNNING (PID 502)"
    assert_lacks "$r" "The camera manager isn't running"
}

test_flags_crash_looping_daemon_listed_without_pid() {
    installed_layout
    launchctl_lists "501|0|com.canon.usa.EWCService" "-|126|com.eos-camera-manager"
    echo "bash: eos-camera-manager.sh: Operation not permitted" > "$HOME/Library/Logs/eos-camera-manager-stderr.log"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "com.eos-camera-manager: LOADED BUT NOT RUNNING (last exit status 126)"
    assert_contains "$r" "The camera manager isn't running"
    assert_contains "$r" "Operation not permitted"
}

test_reports_jobs_that_are_not_loaded() {
    installed_layout
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "com.canon.usa.EWCService: NOT LOADED"
    assert_contains "$r" "com.eos-camera-manager: NOT LOADED"
}

test_warns_about_old_daemon_in_protected_folder() {
    printf '<string>%s/eos-camera-manager.sh</string>\n' "$CLONE" > "$AGENT"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "[WARN] that daemon file does not exist"
    assert_contains "$r" "[WARN] LaunchAgent points at an old install location"
    assert_contains "$r" "[WARN] that is a privacy-protected folder"
}

test_reports_missing_launch_agent() {
    run_diagnose; assert_status "$RC" 0
    assert_contains "$(report)" "LaunchAgent: not installed"
}


test_says_to_review_before_posting() {
    run_diagnose; assert_status "$RC" 0
    assert_contains "$OUT" "Report written to: $HOME/Desktop/eos-webcam-diagnostics.txt"
    assert_contains "$OUT" "REVIEW BEFORE POSTING"
    assert_contains "$(report)" "Read it before posting."
}

# File listings show numeric owners: owner names would give away other
# accounts on the Mac.
test_listings_show_numeric_owners() {
    make_canon_install
    run_diagnose; assert_status "$RC" 0
    local r uid; r="$(report)"; uid="$(/usr/bin/id -u)"
    grep -qE "^d[rwx-]{9}[@+]? +[0-9]+ +$uid +[0-9]+ .* EOSWebcamUtility\.plugin$" "$r" ||
        fail "plug-in listing without a numeric owner: $(grep 'EOSWebcamUtility.plugin$' "$r")"
    assert_lacks "$r" " $(/usr/bin/id -un) "
}

test_writes_to_the_output_option() {
    run_script dist/v1.4/diagnose.sh --output "$SANDBOX/elsewhere.txt"; assert_status "$RC" 0
    assert_file "$SANDBOX/elsewhere.txt"
    assert_contains "$SANDBOX/elsewhere.txt" "===== end of report ====="
    assert_no_file "$(report)"
}

# --- Logs ----------------------------------------------------------------------

# `log show --style compact` output: a runningboardd dump of every running
# app (it names Canon's extension too, which is how the old substring
# predicate caught it), a Canon message listing every camera extension,
# and two useful Canon lines.
plant_logs() {
    cat > "$SANDBOX/log-output" <<'LOG'
2026-09-28 15:46:40.673 Sd runningboardd[427:0] (270709BE-5D5D-3D1E-B663-64D310534E1C) RBConnectionListener
<RBConnectionListener|  clients:[
	osservice<com.apple.PerfPowerServices>:403
	app<application.com.example.SecretDiaryApp.234617373.234617378(501)>:1024
	xpcservice<com.canon.cusa.eoswebcam.cameraExtension(501)>:556
	anon<PrivateChatThing(501)>:777
	]>
2026-09-28 15:46:41.000 Df EOSWebcamService[38585:732c7] [com.apple.cmio:] CMIO_DAL_CMIOExtension_PlugIn.mm:98:-[CMIODALExtensionSession setExtensions:] <private>, extensions {
    "78C120C8-3813-3597-812C-CD4894216BC7" = "<CMIOExtensionInfo: ID com.canon.cusa.eoswebcam.cameraExtension>";
    "57810FF9-E8F3-30E8-BF2C-49014F3EF645" = "<CMIOExtensionInfo: ID com.example.TopSecretVirtualCam>";
}
2026-09-28 15:46:42.000 E  EWCProxy[1576:1a2b] (EDSDK) EdsOpenSession failed: 0x00000081 device busy
2026-09-28 15:46:43.000 Df amfid[361:71a8d] EOSWebcamUtility.plugin/Contents/Resources/EOSWebcamService not valid: The file is adhoc signed
LOG
    export STUB_LOG_OUTPUT="$SANDBOX/log-output"
}

test_log_section_leaves_out_app_lists() {
    plant_logs
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "EWCProxy[1576:1a2b] (EDSDK) EdsOpenSession failed: 0x00000081 device busy"
    assert_contains "$r" "not valid: The file is adhoc signed"
    assert_contains "$r" "<CMIOExtensionInfo: ID com.canon.cusa.eoswebcam.cameraExtension>"
    assert_lacks "$r" "runningboardd"
    assert_lacks "$r" "SecretDiaryApp"
    assert_lacks "$r" "PrivateChatThing"
    assert_lacks "$r" "PerfPowerServices"
    assert_lacks "$r" "TopSecretVirtualCam"
    assert_contains "$r" "(left out: 8 line(s) that list other apps, processes or extensions"
}

# The predicate itself names Canon's processes and subsystems; no bare
# substring or bundle-ID match across every process.
test_log_predicate_is_limited_to_canon() {
    run_diagnose; assert_status "$RC" 0
    local p
    p="$(sed -n 's/^log-arg: \(.*process == .*\)$/\1/p' "$STUB_LOG")"
    [ -n "$p" ] || fail "no predicate passed to log show"
    case "$p" in *'process == "EOSWebcamService"'*'process == "EWCProxy"'*) ;; *) fail "Canon processes not named: $p" ;; esac
    case "$p" in *'subsystem BEGINSWITH "com.canon."'*) ;; *) fail "Canon subsystems not named: $p" ;; esac
    case "$p" in *'CoreMediaIO'*|*'"code signature"'*|*'"library validation"'*|*'"DAL plug"'*) fail "broad substring match left in: $p" ;; esac
    # No eventMessage match at the top level: each one is inside a group
    # ANDed with Canon processes or named daemons.
    printf '%s\n' "$p" | awk '{
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "(") depth++
            else if (c == ")") depth--
            else if (depth == 0 && substr($0, i, 12) == "eventMessage") bad = 1
        }
    } END { exit bad }' || fail "unscoped eventMessage match at the top level of: $p"
}

# --- Redaction -------------------------------------------------------------------

# Make $1 the user: username (id -un), and a home folder named after it
# when $1 can be a folder name.
be_user() {
    export STUB_USERNAME="$1"
    case "$1" in
        */*) ;;
        *)
            export HOME="$SANDBOX/Users/$1"
            mkdir -p "$HOME/Desktop" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" ;;
    esac
}

# Put identifying text in the camera manager log, which the report includes.
plant() {
    printf '%s\n' "$@" >> "$HOME/Library/Logs/eos-camera-manager.log"
}

# The report exists, is complete, and the run said so.
assert_complete_report() {
    assert_status "$RC" 0
    assert_file "$(report)"
    assert_contains "$(report)" "===== end of report ====="
    assert_contains "$(report)" "----- Canon Camera Extension -----"
    assert_contains "$OUT" "Report written to:"
}

test_redacts_a_name_with_an_apostrophe() {
    be_user "obrien"
    export STUB_FULLNAME="Pat O'Brien"
    plant "user obrien here" "full name Pat O'Brien here" "surname O'Brien alone" "home $HOME/Movies"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "O'Brien"
    assert_lacks "$r" "obrien"
    assert_lacks "$r" "Pat "
    assert_lacks "$r" "$HOME"
    assert_contains "$r" "user <user> here"
    assert_contains "$r" "full name <name> here"
    assert_contains "$r" "surname <name> alone"
    assert_contains "$r" "home ~/Movies"
}

# Regex metacharacters are literal: "a.b*c" must not also eat "aXbbbc".
test_redacts_a_name_with_regex_metacharacters() {
    be_user "a.b*c"
    export STUB_FULLNAME="a.b*c"
    plant "literal a.b*c here" "regex bait aXbbbc and abc stays"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "a.b*c"
    assert_contains "$r" "literal <user> here"
    assert_contains "$r" "regex bait aXbbbc and abc stays"
    assert_lacks "$r" "$HOME"
}

test_redacts_a_non_ascii_name() {
    be_user "jose"
    export STUB_FULLNAME="José Müller"
    plant "full José Müller" "first José" "last Müller" "Josen and Müllerin are other words"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "José"
    assert_lacks "$r" "Müller "
    assert_contains "$r" "full <name>"
    assert_contains "$r" "first <name>"
    assert_contains "$r" "last <name>"
    assert_contains "$r" "Josen and Müllerin are other words"
}

# sed's delimiter and replacement metacharacters.
test_redacts_a_name_with_slash_and_ampersand() {
    be_user "xyz"
    export STUB_FULLNAME="x/y&z"
    plant "name x/y&z here" "not x/y or y&z alone"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "x/y&z"
    assert_contains "$r" "name <name> here"
    assert_contains "$r" "not x/y or y&z alone"
}

# A bracket expression as a regex would match single letters.
test_redacts_a_name_in_brackets() {
    be_user "[admin]"
    export STUB_FULLNAME="[admin]"
    plant "user [admin] here" "admin mad dim nim stay"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "[admin]"
    assert_contains "$r" "user <user> here"
    assert_contains "$r" "admin mad dim nim stay"
    assert_contains "$r" "Canon Camera Extension"
}

# A username inside common words: only the whole word is redacted.
test_redacts_a_username_that_is_part_of_common_words() {
    be_user "can"
    export STUB_FULLNAME="Can Cannon"
    plant "we can go" "Canon cannot scan the canal"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "we <user> go"
    assert_contains "$r" "Canon cannot scan the canal"
    assert_contains "$r" "----- Canon camera on USB? -----"
    assert_contains "$r" "Canon Camera Extension"
    assert_lacks "$r" "$HOME"
    assert_lacks "$r" "Cannon"
}

test_redacts_the_computer_name_and_host_name() {
    export STUB_COMPUTER_NAME="Jane’s MacBook Air"
    export STUB_LOCAL_HOST_NAME="Janes-MacBook-Air"
    export STUB_HOSTNAME="janes-air.example.lan"
    plant "on Jane’s MacBook Air" "straight Jane's MacBook Air" "bonjour Janes-MacBook-Air.local" "dns janes-air.example.lan and janes-air"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "Jane"
    assert_lacks "$r" "janes-air"
    assert_contains "$r" "on <computer name>"
    assert_contains "$r" "straight <computer name>"
    assert_contains "$r" "bonjour <computer name>.local"
    assert_contains "$r" "dns <computer name> and <computer name>"
}

test_redacts_addresses_and_other_home_folders() {
    plant "mail jane.doe@example.com now" "ipv4 192.168.1.20 and 10.0.0.1" "ipv6 fe80::1c2b:3a4d:5e6f:7a8b%en0" \
          "mac a4:83:e7:12:34:56 or A4-83-E7-12-34-56" "other /Users/sam/Documents but /Users/Shared stays" \
          "keep std::string, 16:46:40.673, [38585:73319] and v1.2.3.4"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "mail <email> now"
    assert_contains "$r" "ipv4 <ip> and <ip>"
    assert_contains "$r" "ipv6 <ip>%en0"
    assert_contains "$r" "mac <mac> or <mac>"
    assert_contains "$r" "other /Users/<user>/Documents but /Users/Shared stays"
    assert_contains "$r" "keep std::string, 16:46:40.673, [38585:73319] and v1.2.3.4"
}

# Device names of other people, e.g. a Continuity Camera; and no camera
# Model ID / Unique ID fingerprints.
test_camera_list_shows_names_only() {
    cat > "$SANDBOX/cameras" <<'CAMERAS'
Camera:

    EOS Webcam Utility:

      Model ID: EOS
      Unique ID: 0x1100000004a932e9

    Sam’s iPhone Camera:

      Model ID: iPhone17,2
      Unique ID: 5B2A43C1-9E0D-4F4A-8E77-1234567890AB
CAMERAS
    export STUB_SP_CAMERAS="$SANDBOX/cameras"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "  EOS Webcam Utility"
    assert_contains "$r" "  <name>’s iPhone Camera"
    assert_lacks "$r" "Sam"
    assert_lacks "$r" "Unique ID"
    assert_lacks "$r" "Model ID"
    assert_lacks "$r" "0x1100000004a932e9"
    assert_contains "$r" "[PASS] macOS CAN see"
}

# The Mac's serial and hardware UUID, a camera's USB serial, any UUID, and
# a camera's owner name never reach the report, wherever they turn up.
test_no_serial_or_uuid_in_the_report() {
    export STUB_SERIAL="C02ZK1ABMD6T"
    export STUB_HW_UUID="4C4C4544-0042-3510-8052-B4C04F4D3732"
    usb_tree "$(usb_device "Canon Digital Camera" 1193 13033 "CAMSERIAL0042")" > "$SANDBOX/ioreg-usb"
    export STUB_IOREG_USB="$SANDBOX/ioreg-usb"
    cat > "$SANDBOX/log-output" <<'LOG'
2026-09-28 15:46:42.000 E  EWCProxy[1576:1a2b] (EDSDK) camera CAMSERIAL0042 owner: Jane Photographer
2026-09-28 15:46:42.500 E  EWCProxy[1576:1a2b] (EDSDK) Serial Number = 123456789012 BodyID=ABCD1234
2026-09-28 15:46:43.000 Df EOSWebcamService[1433:342b] [com.apple.cmio:] device 0F8E7D6C-5B4A-4392-8170-ABCDEF012345 on C02ZK1ABMD6T 4c4c4544-0042-3510-8052-b4c04f4d3732
LOG
    export STUB_LOG_OUTPUT="$SANDBOX/log-output"
    plant "mac serial C02ZK1ABMD6T" "hw 4C4C4544-0042-3510-8052-B4C04F4D3732" "usb CAMSERIAL0042" "Artist: Jane Photographer" "copyright=Jane Photographer 2026"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_lacks "$r" "C02ZK1ABMD6T"
    assert_lacks "$r" "CAMSERIAL0042"
    assert_lacks "$r" "123456789012"
    assert_lacks "$r" "ABCD1234"
    assert_lacks "$r" "Jane"
    assert_lacks "$r" "IOPlatform"
    if grep -qE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$r"; then
        fail "a UUID is in the report: $(grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$r" | head -1)"
    fi
    assert_contains "$r" "mac serial <serial>"
    assert_contains "$r" "hw <uuid>"
    assert_contains "$r" "usb <serial>"
    assert_contains "$r" "owner: <redacted>"
    assert_contains "$r" "Artist: <redacted>"
    assert_contains "$r" "Canon device on USB: Canon Digital Camera (vendor ID 0x04a9, product ID 0x32e9)"
}

# ~/Library/Application Support/EWCService: the fork's files and Canon's
# config files are listed; Canon's logs and data only counted.
test_runtime_dir_lists_only_known_files() {
    installed_layout
    echo "camera serial CAMSERIAL0042" > "$RUNTIME/log1790610998.txt"
    mkdir -p "$RUNTIME/Camera" "$RUNTIME/backups/pre-v1.4.2-20260314-101010"
    echo "EOS 250D CAMSERIAL0042" > "$RUNTIME/Camera/cameras"
    echo x > "$RUNTIME/Jane Photographer notes.txt"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "eos-camera-manager.sh"
    assert_contains "$r" "config.plist"
    assert_contains "$r" "missing                    proconfig.plist"
    assert_contains "$r" "backup: pre-v1.4.2-20260314-101010"
    assert_contains "$r" "other files and folders (Canon's logs and data; not listed): 3"
    assert_lacks "$r" "log1790610998"
    assert_lacks "$r" "CAMSERIAL0042"
    assert_lacks "$r" "Jane"
    assert_lacks "$r" "cameras"
}

# --- Fail loudly ---------------------------------------------------------------

# Nothing is written (and an older report is removed) unless redaction
# worked; the run exits 1 and says so.
assert_refused_to_write() {
    assert_status "$RC" 1
    assert_contains "$OUT" "ERROR: the report could not be redacted safely, so no report was written"
    assert_lacks "$OUT" "Report written to"
    assert_no_file "$(report)"
    local left
    left="$(find "$HOME/Desktop" -name 'eos-webcam-diagnostics*' 2>/dev/null)"
    [ -z "$left" ] || fail "left behind: $left"
}

old_report() { echo "an older report" > "$(report)"; }

test_refuses_when_redaction_fails() {
    old_report
    export STUB_AWK_REDACT=fail
    run_diagnose; assert_refused_to_write
    assert_contains "$OUT" "the redaction filter failed"
}

# Output that looks complete doesn't count if the filter exited with an error.
test_refuses_when_redaction_exits_with_an_error() {
    old_report
    export STUB_AWK_REDACT=error
    run_diagnose; assert_refused_to_write
    assert_contains "$OUT" "the redaction filter failed"
}

test_refuses_an_empty_report() {
    old_report
    export STUB_AWK_REDACT=empty
    run_diagnose; assert_refused_to_write
    assert_contains "$OUT" "came out empty or cut short"
}

test_refuses_a_near_empty_report() {
    export STUB_AWK_REDACT=truncate
    run_diagnose; assert_refused_to_write
    assert_contains "$OUT" "came out empty or cut short (3 of"
}

test_refuses_a_report_that_still_holds_the_username() {
    be_user "obrien"
    plant "user obrien here"
    export STUB_AWK_REDACT=passthrough
    run_diagnose; assert_refused_to_write
    assert_contains "$OUT" "still hold something that should have been redacted"
    # Only the kind of leftover is named, never the text.
    assert_lacks "$OUT" "user obrien here"
}

# --- Canon camera on USB ---------------------------------------------------------

# ioreg -p IOUSB -l -w0 output: a root, a controller, and the given devices
# behind a hub (like a camera plugged into a monitor).
usb_tree() {
    printf '+-o Root  <class IORegistryEntry, id 0x100000100, retain 35>\n'
    printf '  +-o AppleT8122USBXHCI@00000000  <class AppleT8122USBXHCI, id 0x10000048d, registered, matched, active, busy 0 (1063 ms), retain 287>\n'
    printf '  | {\n  |   "IOClass" = "AppleT8122USBXHCI"\n  | }\n'
    usb_device "USB2.0 Hub" 8457 10274 ""
    printf '%s\n' "$@"
}

# One device: name, vendor ID, product ID, serial number (all decimal).
usb_device() {
    printf '  | +-o %s@00124100  <class IOUSBHostDevice, id 0x100000e05, registered, matched, active, busy 0 (18 ms), retain 28>\n' "$1"
    printf '  | |   {\n'
    printf '  | |     "sessionID" = 1234567\n'
    printf '  | |     "idProduct" = %s\n' "$3"
    printf '  | |     "USB Product Name" = "%s"\n' "$1"
    printf '  | |     "USB Vendor Name" = "Vendor Inc."\n'
    printf '  | |     "idVendor" = %s\n' "$2"
    printf '  | |     "kUSBProductString" = "%s"\n' "$1"
    [ -z "$4" ] || printf '  | |     "USB Serial Number" = "%s"\n  | |     "kUSBSerialNumberString" = "%s"\n' "$4" "$4"
    printf '  | |     "kUSBContainerID" = "9E1F4B2C-1111-2222-3333-444455556666"\n'
    printf '  | |   }\n  | |   \n'
}

test_finds_a_canon_camera_by_vendor_id_whatever_its_name() {
    usb_tree "$(usb_device "EOS R6 Mark II" 1193 13033 "CAMSERIAL0042")" \
             "$(usb_device "G502 LIGHTSPEED Wireless Gaming Mouse" 1133 49293 "MOUSESERIAL1")" > "$SANDBOX/ioreg-usb"
    export STUB_IOREG_USB="$SANDBOX/ioreg-usb"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "(from the USB tree of ioreg)"
    assert_contains "$r" "Canon device on USB: EOS R6 Mark II (vendor ID 0x04a9, product ID 0x32e9)"
    assert_contains "$r" "(3 USB devices seen in all; only Canon ones are listed)"
    assert_lacks "$r" "No Canon device on USB"
    assert_lacks "$r" "G502"
    assert_lacks "$r" "CAMSERIAL0042"
    assert_lacks "$r" "MOUSESERIAL1"
    assert_log_matches '^ioreg -p IOUSB -l -w0$'
}

test_reports_no_canon_device_when_there_are_no_usb_devices() {
    run_diagnose; assert_complete_report
    assert_contains "$(report)" "No Canon device on USB (no device with vendor ID 0x04a9 among 0 USB devices)"
    assert_lacks "$(report)" "Canon device on USB:"
}

# Matched on the vendor ID, not the name.
test_ignores_a_non_canon_device_even_if_named_canon() {
    usb_tree "$(usb_device "Canon Digital Camera" 1133 13033 "")" > "$SANDBOX/ioreg-usb"
    export STUB_IOREG_USB="$SANDBOX/ioreg-usb"
    run_diagnose; assert_complete_report
    assert_contains "$(report)" "No Canon device on USB (no device with vendor ID 0x04a9 among 2 USB devices)"
    assert_lacks "$(report)" "Canon device on USB:"
}

# macOS 26 has no SPUSBDataType: system_profiler prints nothing for it (the
# stub's default), and the camera is still found.
test_finds_the_camera_without_spusbdatatype() {
    usb_tree "$(usb_device "Canon Digital Camera" 1193 12867 "")" > "$SANDBOX/ioreg-usb"
    export STUB_IOREG_USB="$SANDBOX/ioreg-usb"
    run_diagnose; assert_complete_report
    assert_contains "$(report)" "Canon device on USB: Canon Digital Camera (vendor ID 0x04a9, product ID 0x3243)"
    assert_lacks "$STUB_LOG" "system_profiler SPUSBDataType"
}

# Without ioreg data, system_profiler's SPUSBHostDataType (macOS 15+) or
# SPUSBDataType (macOS 13-14) is used, matched on the vendor ID too.
spusb_listing() {
    printf 'USB:\n\n    USB 3.1 Bus:\n\n      Host Controller Driver: AppleT8122USBXHCI\n\n'
    printf '        EOS 250D:\n\n          Product ID: 0x32e9\n          Vendor ID: 0x04a9  (Canon Inc.)\n          Serial Number: CAMSERIAL0042\n\n'
    printf '        Keyboard:\n\n          Product ID: 0x0250\n          Vendor ID: 0x05ac (Apple Inc.)\n'
}

test_falls_back_to_spusbhostdatatype() {
    export STUB_IOREG_FAIL=1
    spusb_listing > "$SANDBOX/spusbhost"
    export STUB_SP_USBHOST="$SANDBOX/spusbhost"
    run_diagnose; assert_complete_report
    local r; r="$(report)"
    assert_contains "$r" "(ioreg gave nothing; from system_profiler SPUSBHostDataType)"
    assert_contains "$r" "Canon device on USB: EOS 250D (vendor ID 0x04a9, product ID 0x32e9)"
    assert_lacks "$r" "CAMSERIAL0042"
    assert_lacks "$r" "Keyboard"
}

test_falls_back_to_spusbdatatype_on_older_macos() {
    export STUB_IOREG_FAIL=1
    spusb_listing > "$SANDBOX/spusb"
    export STUB_SP_USB="$SANDBOX/spusb"
    run_diagnose; assert_complete_report
    assert_contains "$(report)" "(ioreg gave nothing; from system_profiler SPUSBDataType)"
    assert_contains "$(report)" "Canon device on USB: EOS 250D (vendor ID 0x04a9, product ID 0x32e9)"
}

test_says_so_when_usb_cannot_be_listed() {
    export STUB_IOREG_FAIL=1
    run_diagnose; assert_complete_report
    assert_contains "$(report)" "USB devices could not be listed"
    assert_lacks "$(report)" "No Canon device on USB"
}

# The helpers' signatures: this version's install signs them ad hoc with the
# hardened runtime; Canon's are team NC5A977249. Only flags, team and
# entitlement names are shown.
test_reports_the_helpers_signatures() {
    installed_layout
    make_canon_install --patched
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "----- Service and EWCProxy signatures -----"
    assert_contains "$r" "EWCProxy: flags=0x10002(adhoc,runtime) team=not set entitlements: com.apple.security.cs.disable-library-validation com.apple.security.device.camera"
    assert_contains "$r" "crash reports of the service or EWCProxy in the last 7 days: 0 (0 about code signing or library loading)"
    assert_lacks "$r" "crashed with a code-signing"
}

test_canon_signed_helpers_show_canons_team() {
    installed_layout
    make_canon_install
    run_diagnose; assert_status "$RC" 0
    assert_contains "$(report)" "EOSWebcamService: flags=0x10000(runtime) team=NC5A977249"
}

# A helper that can't load EDSDK (library validation) dies at launch: the
# crash reports say so, and the verdict warns. Only counts are reported.
test_warns_about_code_signing_crashes_of_the_helpers() {
    installed_layout
    make_canon_install --patched
    mkdir -p "$HOME/Library/Logs/DiagnosticReports"
    printf 'Termination Reason: Namespace DYLD, Code 1 Library missing\n(mapping process and mapped file (non-platform) have different Team IDs) /Users/secretname/x\n' \
        > "$HOME/Library/Logs/DiagnosticReports/EWCProxy-2026-09-28-101010.ips"
    echo "unrelated" > "$HOME/Library/Logs/DiagnosticReports/EOSWebcamService-2026-09-28-101011.ips"
    run_diagnose; assert_status "$RC" 0
    local r; r="$(report)"
    assert_contains "$r" "crash reports of the service or EWCProxy in the last 7 days: 2 (1 about code signing or library loading)"
    assert_contains "$r" "[WARN] EOSWebcamService or EWCProxy crashed with a code-signing or library-loading"
    assert_lacks "$r" "secretname"
}

run_tests
