#!/bin/bash

set -euo pipefail

readonly SESSION_NAME="kurotty-control-mode-smoke"
readonly OUTPUT_MARKER="KUROTTY_TMUX_OUTPUT"
readonly SPLIT_OUTPUT_MARKER="KUROTTY_TMUX_SPLIT_OUTPUT"
readonly CUTOVER_OUTPUT_MARKER="KUROTTY_TMUX_CUTOVER_0123456789abcdef"
readonly ORDINARY_OUTPUT_MARKER="KUROTTY_TMUX_ORDINARY_OUTPUT"
readonly ORDINARY_SESSION_NAME="kurotty-ordinary-smoke"
readonly WINDOW_INDEX_SUBSCRIPTION_NAME="kurotty-window-index"
readonly WAIT_ATTEMPTS=50
readonly WAIT_INTERVAL_SECONDS=0.1

if [[ -n "${TMUX_BIN:-}" ]]; then
    tmux_bin="$TMUX_BIN"
elif [[ -x /opt/homebrew/bin/tmux ]]; then
    tmux_bin=/opt/homebrew/bin/tmux
elif tmux_path="$(command -v tmux 2>/dev/null)" && [[ -n "$tmux_path" ]]; then
    tmux_bin="$tmux_path"
else
    echo "tmux control-mode smoke test failed: tmux was not found" >&2
    exit 1
fi

if [[ ! -x "$tmux_bin" ]]; then
    echo "tmux control-mode smoke test failed: TMUX_BIN is not executable: $tmux_bin" >&2
    exit 1
fi

readonly tmux_bin
readonly SOCKET_PATH="/tmp/kurotty-tmux-control-mode-smoke-$$.sock"
readonly ORDINARY_SOCKET_PATH="/tmp/kurotty-tmux-ordinary-smoke-$$.sock"
readonly CUTOVER_TRIGGER_PATH="/tmp/kurotty-tmux-cutover-trigger-$$"
readonly CUTOVER_DONE_PATH="/tmp/kurotty-tmux-cutover-done-$$"
CAPTURE_PATH="$(mktemp /tmp/kurotty-tmux-control-mode-smoke.XXXXXX)"
readonly CAPTURE_PATH
ORDINARY_CAPTURE_PATH="$(mktemp /tmp/kurotty-tmux-ordinary-smoke.XXXXXX)"
readonly ORDINARY_CAPTURE_PATH

control_client_pid=""
server_started=0
ordinary_server_started=0

tmux_command() {
    env -u TMUX "$tmux_bin" -S "$SOCKET_PATH" -f /dev/null "$@"
}

ordinary_tmux_command() {
    env -u TMUX "$tmux_bin" -S "$ORDINARY_SOCKET_PATH" -f /dev/null "$@"
}

cleanup() {
    local saved_status=$?

    if [[ -n "$control_client_pid" ]] && kill -0 "$control_client_pid" 2>/dev/null; then
        kill "$control_client_pid" 2>/dev/null || true
        wait "$control_client_pid" 2>/dev/null || true
    fi
    control_client_pid=""

    if [[ "$server_started" -eq 1 ]]; then
        tmux_command kill-server >/dev/null 2>&1 || true
    fi
    server_started=0

    if [[ "$ordinary_server_started" -eq 1 ]]; then
        ordinary_tmux_command kill-server >/dev/null 2>&1 || true
    fi
    ordinary_server_started=0

    rm -f \
        "$SOCKET_PATH" \
        "$ORDINARY_SOCKET_PATH" \
        "$CAPTURE_PATH" \
        "$ORDINARY_CAPTURE_PATH" \
        "$CUTOVER_TRIGGER_PATH" \
        "$CUTOVER_DONE_PATH"
    return "$saved_status"
}

handle_signal() {
    trap - INT TERM
    exit 130
}

fail() {
    echo "tmux control-mode smoke test failed: $1" >&2
    if [[ -s "$CAPTURE_PATH" ]]; then
        echo "--- captured control-mode stream ---" >&2
        LC_ALL=C strings "$CAPTURE_PATH" >&2 || true
        echo "--- end captured stream ---" >&2
    fi
    if [[ -s "$ORDINARY_CAPTURE_PATH" ]]; then
        echo "--- captured ordinary tmux stream ---" >&2
        LC_ALL=C strings "$ORDINARY_CAPTURE_PATH" >&2 || true
        echo "--- end captured ordinary stream ---" >&2
    fi
    exit 1
}

wait_for_control_client() {
    local attempt
    local client_tty

    for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
        client_tty="$(tmux_command list-clients -F '#{client_tty}' 2>/dev/null | head -n 1 || true)"
        if [[ -n "$client_tty" ]]; then
            printf '%s' "$client_tty"
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_path_pattern() {
    local capture_path=$1
    local pattern=$2
    local attempt

    for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
        if LC_ALL=C grep -Fq "$pattern" "$capture_path"; then
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_capture_pattern() {
    local pattern=$1

    wait_for_path_pattern "$CAPTURE_PATH" "$pattern"
}

wait_for_path() {
    local path=$1
    local attempt

    for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
        if [[ -e "$path" ]]; then
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_pane_capture_line() {
    local pane_id=$1
    local expected_line=$2
    local attempt
    local pane_capture

    for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
        pane_capture="$(tmux_command capture-pane -p -S - -t "$pane_id")"
        if LC_ALL=C grep -Fxq "$expected_line" <<<"$pane_capture"; then
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_process_exit() {
    local pid=$1
    local attempt

    for ((attempt = 0; attempt < WAIT_ATTEMPTS; attempt += 1)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep "$WAIT_INTERVAL_SECONDS"
    done
    return 1
}

assert_capture_contains() {
    local pattern=$1
    local description=$2

    LC_ALL=C grep -Fq "$pattern" "$CAPTURE_PATH" || fail "missing $description"
}

trap cleanup EXIT
trap handle_signal INT TERM

rm -f \
    "$SOCKET_PATH" \
    "$ORDINARY_SOCKET_PATH" \
    "$CUTOVER_TRIGGER_PATH" \
    "$CUTOVER_DONE_PATH"
server_started=1
tmux_command new-session -d -s "$SESSION_NAME" -n first "exec /bin/sh"

# tmux control mode requires a terminal. macOS `script` supplies an isolated PTY
# while stdout captures the exact DCS-framed protocol stream for assertions.
script -q /dev/null \
    env -u TMUX "$tmux_bin" -S "$SOCKET_PATH" -f /dev/null \
    -CC attach-session -t "$SESSION_NAME" \
    </dev/null >"$CAPTURE_PATH" 2>&1 &
control_client_pid=$!

client_tty="$(wait_for_control_client)" || fail "control client did not attach"
client_state="$(tmux_command list-clients -F '#{client_tty}|#{client_control_mode}')"
client_count="$(tmux_command list-clients -F '#{client_tty}' | awk 'END { print NR }')"
[[ "$client_count" == 1 ]] || fail "exactly one attached client for sole-client cutover"
[[ "$client_state" == "${client_tty}|1" ]] || fail "sole attached client to be in control mode"

tmux_command new-window \
    -t "${SESSION_NAME}:" \
    -n second \
    "printf '${OUTPUT_MARKER}\\n'; exec /bin/sh"
tmux_command split-window \
    -h \
    -t "${SESSION_NAME}:second" \
    "printf '${SPLIT_OUTPUT_MARKER}\\n'; exec /bin/sh"

window_state="$(tmux_command list-windows -t "$SESSION_NAME" -F '#{window_name}|#{window_panes}')"
grep -Fxq 'first|1' <<<"$window_state" || fail "one-pane first window"
grep -Fxq 'second|2' <<<"$window_state" || fail "two-pane second window"

second_layout="$(tmux_command display-message -p -t "${SESSION_NAME}:second" '#{window_layout}')"
if [[ "$second_layout" != *'{'*'}'* ]]; then
    fail "horizontal split layout in tmux state"
fi

second_window_id="$(tmux_command display-message -p -t "${SESSION_NAME}:second" '#{window_id}')"
first_window_id="$(tmux_command display-message -p -t "${SESSION_NAME}:first" '#{window_id}')"
first_pane_id="$(tmux_command list-panes -t "${SESSION_NAME}:second" -F '#{pane_id}' | head -n 1)"
preflight_attached_count="$(tmux_command display-message -p -t "$first_pane_id" '#{session_attached}')"
[[ "$preflight_attached_count" == 1 ]] \
    || fail "sole-client preflight session_attached format"
extended_key_state="$(tmux_command list-panes \
    -t "$first_pane_id" \
    -f "#{==:#{pane_id},$first_pane_id}" \
    -F '#{extended_keys_format}|#{extended-keys-format}|#{pane_key_mode}|#{origin_flag}')"
[[ "$extended_key_state" == '|xterm|VT10x|0' ]] \
    || fail "hyphenated extended-keys-format and pane key-mode state"
tmux_command resize-pane -Z -t "$first_pane_id"
[[ "$(tmux_command display-message -p -t "$first_pane_id" '#{window_zoomed_flag}')" == 1 ]] \
    || fail "pane zoom command"
tmux_command resize-pane -Z -t "$first_pane_id"
tmux_command rotate-window -D -t "$second_window_id"
tmux_command swap-pane -D -t "$first_pane_id"
tmux_command select-layout -t "$first_pane_id" even-horizontal >/dev/null
tmux_command select-layout -t "$first_pane_id" even-vertical >/dev/null
tmux_command select-layout -n -t "$first_pane_id" >/dev/null
tmux_command resize-pane -t "$first_pane_id" -x 30 -y 10

tmux_command refresh-client \
    -t "$client_tty" \
    -B "${WINDOW_INDEX_SUBSCRIPTION_NAME}:@*:#{window_index}"
tmux_command swap-window -d -s "$first_window_id" -t "$second_window_id"
swapped_window_order="$(tmux_command list-windows -O index -t "$SESSION_NAME" -F '#{window_id}')"
expected_swapped_window_order="$(printf '%s\n%s' "$second_window_id" "$first_window_id")"
[[ "$swapped_window_order" == "$expected_swapped_window_order" ]] \
    || fail "window order after swap-window"
wait_for_capture_pattern "%subscription-changed ${WINDOW_INDEX_SUBSCRIPTION_NAME} " \
    || fail "window-index subscription notification after swap-window"

wait_for_capture_pattern "$OUTPUT_MARKER" || fail "first pane output event"
wait_for_capture_pattern "$SPLIT_OUTPUT_MARKER" || fail "split pane output event"

# With a sole control client, pane:off makes tmux stop reading that pane's PTY.
# The file handshake proves the pane wrote its marker while off; both the control
# stream and capture-pane must remain unchanged until pane:on drains the PTY.
cutover_shell_command="while [ ! -e '$CUTOVER_TRIGGER_PATH' ]; do sleep 0.02; done; printf '%s\\n' '$CUTOVER_OUTPUT_MARKER'; touch '$CUTOVER_DONE_PATH'; exec /bin/sh"
cutover_window_id="$(tmux_command new-window \
    -d \
    -P \
    -F '#{window_id}' \
    -t "${SESSION_NAME}:" \
    -n cutover \
    "$cutover_shell_command")"
cutover_pane_id="$(tmux_command list-panes -t "$cutover_window_id" -F '#{pane_id}')"
[[ -n "$cutover_pane_id" ]] || fail "cutover pane creation"

tmux_command refresh-client -t "$client_tty" -A "${cutover_pane_id}:off"
touch "$CUTOVER_TRIGGER_PATH"
wait_for_path "$CUTOVER_DONE_PATH" || fail "cutover pane producer completion while pane was off"
sleep 0.2

if LC_ALL=C grep -Fq "$CUTOVER_OUTPUT_MARKER" "$CAPTURE_PATH"; then
    fail "cutover output to remain absent from control stream while pane was off"
fi
cutover_capture_while_off="$(tmux_command capture-pane -p -S - -t "$cutover_pane_id")"
if LC_ALL=C grep -Fq "$CUTOVER_OUTPUT_MARKER" <<<"$cutover_capture_while_off"; then
    fail "cutover output to remain absent from capture-pane while pane was off"
fi

tmux_command refresh-client -t "$client_tty" -A "${cutover_pane_id}:on"
wait_for_capture_pattern "$CUTOVER_OUTPUT_MARKER" \
    || fail "cutover output in control stream after pane was turned on"
wait_for_pane_capture_line "$cutover_pane_id" "$CUTOVER_OUTPUT_MARKER" \
    || fail "lossless cutover output in capture-pane after pane was turned on"
cutover_capture_after_on="$(tmux_command capture-pane -p -S - -t "$cutover_pane_id")"
cutover_marker_count="$(LC_ALL=C grep -Fxc "$CUTOVER_OUTPUT_MARKER" <<<"$cutover_capture_after_on" || true)"
[[ "$cutover_marker_count" == 1 ]] || fail "exactly one complete cutover marker after pane was turned on"

tmux_command detach-client -t "$client_tty"
wait_for_capture_pattern '%exit' || fail "control-mode detach notification"
wait_for_process_exit "$control_client_pid" || fail "control client process exit after detach"
wait "$control_client_pid"
control_client_pid=""

if [[ -n "$(tmux_command list-clients -F '#{client_tty}' 2>/dev/null || true)" ]]; then
    fail "detached control client to be absent"
fi

readonly control_enter_marker=$'\033P1000p'
readonly control_exit_marker=$'\033\\'
assert_capture_contains "$control_enter_marker" "DCS control-mode entry marker"
assert_capture_contains '%session-changed ' "session attachment event"
assert_capture_contains "$SESSION_NAME" "attached session name"
assert_capture_contains '%window-add @' "window creation event"
assert_capture_contains '%layout-change @' "pane layout-change event"
assert_capture_contains '{' "horizontal split layout payload"
assert_capture_contains '%output %' "pane output event"
assert_capture_contains "$OUTPUT_MARKER" "first pane output payload"
assert_capture_contains "$SPLIT_OUTPUT_MARKER" "split pane output payload"
assert_capture_contains "$CUTOVER_OUTPUT_MARKER" "lossless pane off/on cutover payload"
assert_capture_contains \
    "%subscription-changed ${WINDOW_INDEX_SUBSCRIPTION_NAME} " \
    "window-index subscription event"
assert_capture_contains '%exit' "detach event"
assert_capture_contains "$control_exit_marker" "DCS control-mode exit marker"

tmux_command kill-server
if env -u TMUX "$tmux_bin" -S "$SOCKET_PATH" -f /dev/null has-session 2>/dev/null; then
    fail "isolated tmux server cleanup"
fi
server_started=0
rm -f "$SOCKET_PATH"

# A separate ordinary attach under a PTY must render pane output without entering
# the DCS-framed control protocol used by -CC.
ordinary_server_started=1
ordinary_tmux_command new-session \
    -d \
    -s "$ORDINARY_SESSION_NAME" \
    -n ordinary \
    "printf '${ORDINARY_OUTPUT_MARKER}\\n'; exec /bin/sh"
script -q /dev/null \
    env -u TMUX TERM=xterm-256color \
    "$tmux_bin" -S "$ORDINARY_SOCKET_PATH" -f /dev/null \
    attach-session -t "$ORDINARY_SESSION_NAME" \
    </dev/null >"$ORDINARY_CAPTURE_PATH" 2>&1

LC_ALL=C grep -Fq "$ORDINARY_OUTPUT_MARKER" "$ORDINARY_CAPTURE_PATH" \
    || fail "ordinary tmux pane output after detach"
if LC_ALL=C grep -Fq "$control_enter_marker" "$ORDINARY_CAPTURE_PATH"; then
    fail "ordinary tmux capture to omit DCS P1000p control-mode entry marker"
fi

ordinary_tmux_command kill-server >/dev/null 2>&1 || true
if env -u TMUX "$tmux_bin" -S "$ORDINARY_SOCKET_PATH" -f /dev/null has-session 2>/dev/null; then
    fail "isolated ordinary tmux server cleanup"
fi
ordinary_server_started=0
rm -f "$ORDINARY_SOCKET_PATH"

echo "tmux control-mode and ordinary-client smoke tests passed: $($tmux_bin -V)"
