#!/usr/bin/env bash

set -uo pipefail

RESULTS_FILE=".ci/example-results.txt"
FAILURES_FILE=".ci/example-failures.txt"
LOG_DIRECTORY=".ci/example-logs"
MANIFEST_PATH="${EXAMPLE_MANIFEST_PATH:-.ci/examples-manifest.txt}"
DEFAULT_TIMEOUT_SECONDS="${DEFAULT_TIMEOUT_SECONDS:-180}"

declare -A EXAMPLE_MODE
declare -A EXAMPLE_TIMEOUT
declare -A EXAMPLE_ARGS
declare -A EXAMPLE_NOTE

load_manifest()
{
  if [[ ! -f "$MANIFEST_PATH" ]]; then
    return
  fi

  while IFS='|' read -r name mode timeout args note; do
    [[ -z "${name// }" ]] && continue
    [[ "${name:0:1}" == "#" ]] && continue

    mode="${mode:-run}"
    timeout="${timeout:-$DEFAULT_TIMEOUT_SECONDS}"

    EXAMPLE_MODE["$name"]="$mode"
    EXAMPLE_TIMEOUT["$name"]="$timeout"
    EXAMPLE_ARGS["$name"]="$args"
    EXAMPLE_NOTE["$name"]="$note"
  done < "$MANIFEST_PATH"
}

resolve_executables_directory()
{
  local -a candidates=()

  if [[ -n "${EXECUTABLES_DIRECTORY:-}" ]]; then
    candidates+=("$EXECUTABLES_DIRECTORY")
  fi

  candidates+=(
    "build/linux-x64-release/src/sdk/examples/Release"
    "package/Release/Linux/x86_64/examples/Release"
    "build/linux-x64-debug/src/sdk/examples/Debug"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

record_result()
{
  local name="$1"
  local result="$2"
  local timeout="$3"
  local args="$4"
  local note="$5"
  local log_path="$6"

  printf "| %s | %s | %s | %s | %s | %s |\n" \
    "$name" "$result" "$timeout" "$args" "$note" "$log_path" >> "$RESULTS_FILE"
}

append_failure_log()
{
  local name="$1"
  local exit_code="$2"
  local log_path="$3"

  {
    echo "[$name] exit-code=$exit_code"
    if [[ -f "$log_path" ]]; then
      tail -n 80 "$log_path"
    else
      echo "Log file not found: $log_path"
    fi
    echo
  } >> "$FAILURES_FILE"
}

mkdir -p "$LOG_DIRECTORY"

{
  echo "| Example | Result | Timeout(s) | Args | Note | Log |"
  echo "|---|---|---:|---|---|---|"
} > "$RESULTS_FILE"

: > "$FAILURES_FILE"

load_manifest

EXEC_DIR="$(resolve_executables_directory)" || {
  echo "Unable to locate example executables directory." >&2
  exit 1
}

echo "Using example executables from: $EXEC_DIR"

export HIERO_NETWORK="${HIERO_NETWORK:-testnet}"
export NETWORK_NAME="${NETWORK_NAME:-$HIERO_NETWORK}"

shopt -s nullglob
EXECUTABLES=()
for executable_path in "$EXEC_DIR"/*; do
  if [[ -f "$executable_path" ]] && [[ -x "$executable_path" ]]; then
    EXECUTABLES+=("$(basename "$executable_path")")
  fi
done
shopt -u nullglob

if [[ "${#EXECUTABLES[@]}" -gt 0 ]]; then
  mapfile -t EXECUTABLES < <(printf '%s\n' "${EXECUTABLES[@]}" | LC_ALL=C sort)
fi

if [[ "${#EXECUTABLES[@]}" -eq 0 ]]; then
  echo "No executables found in $EXEC_DIR" >&2
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

echo "Discovered ${#EXECUTABLES[@]} executable examples"

for executable_name in "${EXECUTABLES[@]}"; do
  executable_path="$EXEC_DIR/$executable_name"
  mode="${EXAMPLE_MODE[$executable_name]:-run}"
  timeout_seconds="${EXAMPLE_TIMEOUT[$executable_name]:-$DEFAULT_TIMEOUT_SECONDS}"
  extra_args="${EXAMPLE_ARGS[$executable_name]:-}"
  note="${EXAMPLE_NOTE[$executable_name]:-}"
  log_path="$LOG_DIRECTORY/${executable_name}.log"

  if [[ "$mode" == "skip" ]]; then
    echo "SKIP $executable_name (${note:-no reason provided})"
    record_result "$executable_name" "SKIPPED" "$timeout_seconds" "$extra_args" "$note" "$log_path"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    continue
  fi

  echo "RUN  $executable_name (timeout=${timeout_seconds}s args='${extra_args}')"

  read -r -a arg_array <<< "$extra_args"

  if timeout --signal=TERM --kill-after=10s "${timeout_seconds}s" "$executable_path" "${arg_array[@]}" > "$log_path" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo "PASS $executable_name"
    record_result "$executable_name" "PASS" "$timeout_seconds" "$extra_args" "$note" "$log_path"
    PASS_COUNT=$((PASS_COUNT + 1))
    continue
  fi

  if [[ "$exit_code" -eq 124 ]] || [[ "$exit_code" -eq 137 ]]; then
    echo "TIMEOUT $executable_name"
    record_result "$executable_name" "TIMEOUT" "$timeout_seconds" "$extra_args" "$note" "$log_path"
  else
    echo "FAIL $executable_name (exit=${exit_code})"
    record_result "$executable_name" "FAIL($exit_code)" "$timeout_seconds" "$extra_args" "$note" "$log_path"
  fi

  append_failure_log "$executable_name" "$exit_code" "$log_path"
  FAIL_COUNT=$((FAIL_COUNT + 1))
done

echo
echo "Example run summary: pass=$PASS_COUNT fail=$FAIL_COUNT skipped=$SKIP_COUNT"
echo "Detailed results: $RESULTS_FILE"
echo "Failure logs: $FAILURES_FILE"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
