#!/bin/zsh

set -e

function uri_encode() {
    echo "${1}" | jq -Rj @uri
}

function join_list_args() {
    local _key=$1
    shift
    local _list=("$@")
    local _result=()
    for i in {1..$#_list}; do
        local command="${_list[${i}]}"
        local encoded_command=$(uri_encode "${command}")
        _result+=("${_key}=${encoded_command}")
    done
    echo $(IFS='&'; echo "${_result[*]}")
}

# When asking Bazel to launch a simulator, we need to intercept
# the launched process' PID to be able to debug it later on.
# We do this by asking it to write this info to a file.
# These two paths are also hardcoded in the lldb_inject_settings.py script.
INFO_JSON=$(mktemp)

# FIXME: Could not figure out how to make stdout show up on the dedicated
# debug console. So we need to keep this script alive and display it here in the meantime.
BAZEL_APPLE_PREFER_PERSISTENT_SIMS=1 \
BAZEL_APPLE_LAUNCH_INFO_PATH=${INFO_JSON} \
BAZEL_SIMCTL_LAUNCH_FLAGS="--wait-for-debugger --stdout=$(tty) --stderr=$(tty)" \
bazelisk run "${BAZEL_LABEL_TO_RUN}"

WORKSPACE_ROOT=$(pwd)
OUTPUT_BASE=$(bazelisk info output_base)
PID=$(jq -r '.pid' "${INFO_JSON}")
DEVICE_PLATFORM=$(jq -r '.platform' "${INFO_JSON}")
DEVICE_UDID=$(jq -r '.udid' "${INFO_JSON}")
ATTACH_COMMANDS=()
TERMINATE_COMMANDS=()

# Kill the app when debugging ends, just like in Xcode.
TERMINATE_COMMANDS+=("?platform shell kill -- -9 ${PID}")

# Set `CWD` to the Bazel execution root so relative paths in binaries work.
#
# This is needed because we use the `oso_prefix_is_pwd` feature, which makes the
# paths to archives relative to the exec root.
ATTACH_COMMANDS+=("platform settings -w \"${OUTPUT_BASE}/execroot/_main\"")

# Adjust the source map.
#
# The source map will be initialized to the workspace. Need to resolve external
# paths to the stable external directory. Then need to resolve generated files
# to the execution root. We set it for `./` instead of `./bazel-out/` to allow
# the convenience symlink to be used if it exists.
ATTACH_COMMANDS+=("settings insert-before target.source-map 0 \"./external/\" \"${OUTPUT_BASE}/external/\"")
ATTACH_COMMANDS+=("settings append target.source-map \"./\" \"${OUTPUT_BASE}/execroot/_main/\"")

# Finally, connect to the app.
ATTACH_COMMANDS+=("platform select ${DEVICE_PLATFORM}")
ATTACH_COMMANDS+=("platform connect ${DEVICE_UDID}")
ATTACH_COMMANDS+=("process attach --pid ${PID}")

ENCODED_ROOT=$(uri_encode "${WORKSPACE_ROOT}")
ENCODED_NAME=$(uri_encode "Debug ${BAZEL_LABEL_TO_RUN}")
BASE_DAP_URL="cursor://llvm-vs-code-extensions.lldb-dap"

ATTACH_COMMANDS_ARG=$(join_list_args "attachCommands" ${ATTACH_COMMANDS[@]})
TERMINATE_COMMANDS_ARG=$(join_list_args "terminateCommands" ${TERMINATE_COMMANDS[@]})

echo "Launching LLDB..."
FULL_DAP_LAUNCH_URL="${BASE_DAP_URL}/start?name=${ENCODED_NAME}&request=attach&debuggerRoot=${ENCODED_ROOT}&${ATTACH_COMMANDS_ARG}&${TERMINATE_COMMANDS_ARG}"
open "${FULL_DAP_LAUNCH_URL}"

# Give lldb some time to start up.
sleep 2

# FIXME: Need to somehow get the PID of this actual session.
# FIXME (2): Only necessary because of the stdout-related FIXME mentioned in the beginning
LLDB_PID=$(pgrep -lfa "lldb-dap" | head -n 1)
LLDB_PID=$(echo "${LLDB_PID}" | cut -d " " -f 1)

# Keep the terminal alive until the debugging session is killed. We can't watch the app itself unfortunately
# because not all lldb-dap killings trigger TERMINATE_COMMANDS_ARG, which confuses Cursor.
# FIXME: Only necessary because of the stdout-related FIXME mentioned in the beginning
lsof -p ${LLDB_PID} +r 1 &>/dev/null