#!/bin/bash
# measure-fps.sh: the read-only frame rate measurement the user runs on a
# real Mac with the camera connected. Here ffmpeg is a stub that plays back
# recorded output (tests/fixtures/ffmpeg/<scenario>/), so nothing opens a
# camera:
#   devices.txt, modes.txt, capture.err  ffmpeg's avfoundation output, in the
#       format of the ffmpeg 8.0.1 libavdevice strings ("AVFoundation video
#       devices:", "Supported modes:", "  %dx%d@[%f %f]fps", the Stream line)
#   frames.txt  recorded from the real ffmpeg 8.0.1 (-c copy -f framemd5 -)
#       on synthetic 1920x1080 uyvy422 frames with avfoundation-style
#       microsecond timestamps and jitter (setts bsf): "before" is 60 fps
#       with 26 new pictures a second (what v1.4.2 advertised), "after" 30
#       fps with 26 new, "loading" 30 fps of one still picture.
. "$(dirname "$0")/helpers.sh"

run_measure() {
    [ "$(command -v ffmpeg)" = "$STUBS_DIR/ffmpeg" ] || die "ffmpeg is not stubbed"
    if (cd "$CLONE" && /bin/bash dist/v1.4/measure-fps.sh "$@") > "$OUT" 2>&1; then RC=0; else RC=$?; fi
}

# Value of KEY in the RESULT line for device $2 (default 1).
result() {
    /usr/bin/awk -v key="$1" -v dev="device=${2:-1}" '
        $1 == "RESULT" && $2 == dev {
            for (i = 3; i <= NF; i++) { n = index($i, "="); if (substr($i, 1, n - 1) == key) print substr($i, n + 1) }
        }' "$OUT" | head -1
}
# Is number $1 within [$2, $3]?
between() { /usr/bin/python3 -c 'import sys; a, lo, hi = map(float, sys.argv[1:]); sys.exit(not lo <= a <= hi)' "$1" "$2" "$3"; }
assert_between() {  # KEY LO HI [DEVICE]
    local v; v="$(result "$1" "${4:-1}")"
    [ -n "$v" ] || { fail "no $1 in the RESULT line"; return 0; }
    between "$v" "$2" "$3" || fail "$1 = $v, expected $2..$3"
}

test_after_the_fix_reports_30_advertised_30_delivered_26_new() {
    export STUB_FFMPEG_SCENARIO=after
    run_measure --seconds 3 --warmup 1; assert_status "$RC" 0
    assert_contains "$OUT" "read-only: nothing is saved or changed"
    assert_contains "$OUT" "device [1] EOS Webcam Utility"
    assert_contains "$OUT" "    1920x1080 @ 30.00-30.00 fps"
    assert_contains "$OUT" "    640x480 @ 30.00-30.00 fps"
    assert_contains "$OUT" "requested: 1920x1080 @ 30.00 fps"
    assert_contains "$OUT" "negotiated: 1920x1080 uyvy422, 30 fps"
    [ "$(result advertised_fps)" = 30.00 ] || fail "advertised_fps = $(result advertised_fps)"
    [ "$(result negotiated)" = "1920x1080@30" ] || fail "negotiated = $(result negotiated)"
    assert_between delivered_fps 29.0 31.0
    assert_between new_fps 25.0 27.0
    assert_between interval_ms_mean 32.0 35.0
    assert_between seconds 2.8 3.2
    assert_between frames 85 95
    assert_contains "$OUT" "verdict: apps are told 30 fps, frames arrive at 30."
    assert_contains "$OUT" "of them a second are new pictures"
    # It asked ffmpeg for the advertised rate, copied frames without
    # decoding or re-timing, and wrote them nowhere but the hash stream.
    assert_log_matches "^ffmpeg .* -f avfoundation -video_size 1920x1080 -framerate 30\\.000000 -i 1:none -t 4 -map 0:v:0 -c copy -f framemd5 -$"
    assert_log_matches "^ffmpeg .* -f avfoundation -list_devices true -i $"
    # Only the EOS device is named in the report, not the Mac's other cameras.
    assert_lacks "$OUT" "FaceTime"
    assert_lacks "$OUT" "Capture screen"
}

test_before_the_fix_shows_60_advertised_but_26_new_pictures() {
    export STUB_FFMPEG_SCENARIO=before
    run_measure --seconds 3 --warmup 1; assert_status "$RC" 0
    assert_contains "$OUT" "1920x1080 @ 60.00-60.00 fps"
    assert_log_matches "-framerate 60\\.000000 -i 1:none"
    [ "$(result advertised_fps)" = 60.00 ] || fail "advertised_fps = $(result advertised_fps)"
    assert_between delivered_fps 59.0 61.0
    assert_between new_fps 25.0 27.0
    assert_between interval_ms_mean 16.0 17.8
    assert_contains "$OUT" "apps are told 60 fps"
    assert_contains "$OUT" "of them a second are new pictures"
    assert_contains "$OUT" "(longest run of one picture: 3 frames)"
}

test_a_still_loading_screen_is_reported_as_not_live() {
    export STUB_FFMPEG_SCENARIO=loading
    run_measure --seconds 3 --warmup 1; assert_status "$RC" 0
    [ "$(result new_fps)" = 0.00 ] || fail "new_fps = $(result new_fps)"
    assert_contains "$OUT" "the camera isn't live yet"
}

test_two_devices_with_the_name_are_both_measured() {
    export STUB_FFMPEG_SCENARIO=two-devices
    run_measure --seconds 3 --warmup 1; assert_status "$RC" 0
    assert_contains "$OUT" "2 devices are called \"EOS Webcam Utility\""
    assert_contains "$OUT" "device [1] EOS Webcam Utility"
    assert_contains "$OUT" "device [2] EOS Webcam Utility"
    assert_log_matches "-i 2:none -t 4 -map 0:v:0 -c copy -f framemd5 -$"
    assert_between delivered_fps 29.0 31.0 2
}

test_no_eos_device_is_an_error() {
    mkdir -p "$SANDBOX/ff"
    grep -v "EOS Webcam Utility" "$FIXTURES/ffmpeg/after/devices.txt" > "$SANDBOX/ff/devices.txt"
    export STUB_FFMPEG_DIR="$SANDBOX/ff"
    run_measure; assert_status "$RC" 1
    assert_contains "$OUT" "No video device called \"EOS Webcam Utility\" was found."
    assert_lacks "$STUB_LOG" "framemd5"
}

test_a_failed_capture_says_so() {
    export STUB_FFMPEG_SCENARIO=after STUB_FFMPEG_CAPTURE_FAIL=1
    run_measure --seconds 3 --warmup 1
    [ "$RC" != 0 ] || fail "a failed capture exited 0"
    assert_contains "$OUT" "ffmpeg stopped with an error:"
    assert_contains "$OUT" "Failed to create AV capture input device"
    assert_contains "$OUT" "no frames arrived"
}

test_without_ffmpeg_it_installs_nothing() {
    local rc=0
    [ -z "$(PATH=/usr/bin:/bin command -v ffmpeg)" ] || die "an ffmpeg outside the stubs is on /usr/bin:/bin"
    (cd "$CLONE" && PATH=/usr/bin:/bin /bin/bash dist/v1.4/measure-fps.sh) > "$OUT" 2>&1 || rc=$?
    assert_status "$rc" 2
    assert_contains "$OUT" "ffmpeg is needed and isn't installed"
    assert_contains "$OUT" "Nothing was installed or changed."
}

test_bad_arguments_are_refused() {
    run_measure --seconds abc; assert_status "$RC" 1
    assert_contains "$OUT" "take a whole number"
    run_measure --bogus; assert_status "$RC" 1
    assert_lacks "$STUB_LOG" "ffmpeg"
}

# Read-only: it never runs anything that changes the system, never saves
# frames to a file, and only ever deletes its own temp files.
test_the_script_is_read_only() {
    local s="$CLONE/dist/v1.4/measure-fps.sh" code
    # The code, without comments and without the text it prints.
    code="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*echo ' "$s")"
    local w
    for w in sudo osascript launchctl installer codesign pkgutil 'brew install' curl 'rm -r' ditto chown chmod; do
        ! printf '%s\n' "$code" | grep -qF -- "$w" || fail "measure-fps.sh runs $w"
    done
    # Every ffmpeg output is framemd5 to stdout, or none (-i only).
    printf '%s\n' "$code" | grep -E '^[[:space:]]*-i ' | grep -vqE -- '-f framemd5 -( |\\|$)' &&
        fail "an ffmpeg call writes somewhere other than the framemd5 hash stream"
    # rm only ever names its own temp files.
    printf '%s\n' "$code" | grep -E '(^|[^a-z])rm ' | grep -vqF 'rm -f "$TMP/' && fail "rm of something other than its temp files"
    export STUB_FFMPEG_SCENARIO=after
    run_measure --seconds 3 --warmup 1; assert_status "$RC" 0
    assert_no_file "$HOME/Desktop/fps.txt"
    [ -z "$(find "$SANDBOX" -newer "$STUB_LOG" -type f \( -name '*.jpg' -o -name '*.png' -o -name '*.mov' -o -name '*.mp4' -o -name '*.yuv' -o -name '*.raw' \) 2>/dev/null)" ] ||
        fail "an image or video file was written"
}

run_tests
