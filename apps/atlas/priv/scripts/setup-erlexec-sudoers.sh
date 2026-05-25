#!/usr/bin/env bash
#
# setup-erlexec-sudoers.sh
#
# Grants a named local user passwordless sudo on a single binary — the
# `erlexec` SUID port executable that the Erlang `:exec` application
# uses to spawn OS processes as other users. Atlas calls this script
# from `mix atlas.deploy.init` after `mix deps.compile erlexec` has
# materialised the port binary on disk.
#
# The script is idempotent: it overwrites `/etc/sudoers.d/erlexec` each
# time it runs, validates the result with `visudo -c`, and rolls back
# (deletes the file) if validation fails so a broken sudoers entry can
# never lock the host out.
#
# Usage:
#   sudo ./setup-erlexec-sudoers.sh --user <name> --binary <path>
#
# Flags:
#   --user    Required. The Unix account that should be granted sudo
#             on the binary.
#   --binary  Required. Absolute path to the erlexec exec-port binary.
#             Must already exist and be a regular file.
#   --file    Optional. Sudoers file to write. Defaults to
#             /etc/sudoers.d/erlexec.
#   --help    Print this help and exit 0.
#
# Exit codes:
#   0  success (sudoers entry written and validated)
#   1  bad arguments or precondition (missing flag, binary not found,
#      user not present on host)
#   2  sudoers validation failed; the broken file was removed before
#      this script exited

set -euo pipefail

PROG="$(basename "$0")"

USER_NAME=""
BINARY_PATH=""
SUDOERS_FILE="/etc/sudoers.d/erlexec"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="${2:-}"; shift 2 ;;
    --binary)
      BINARY_PATH="${2:-}"; shift 2 ;;
    --file)
      SUDOERS_FILE="${2:-}"; shift 2 ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "$PROG: unknown flag: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

if [[ -z "$USER_NAME" ]]; then
  echo "$PROG: --user is required" >&2
  exit 1
fi

if [[ -z "$BINARY_PATH" ]]; then
  echo "$PROG: --binary is required" >&2
  exit 1
fi

if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  echo "$PROG: user '$USER_NAME' does not exist on this host" >&2
  exit 1
fi

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "$PROG: binary not found: $BINARY_PATH" >&2
  exit 1
fi

# Resolve to an absolute, canonical path so sudoers doesn't accept a
# different binary at the same logical location later.
ABS_BINARY="$(cd "$(dirname "$BINARY_PATH")" && pwd)/$(basename "$BINARY_PATH")"

# Write atomically to a temp file in the same directory, validate,
# then mv into place. visudo -c on the destination after the mv gives
# a final cross-check.
TARGET_DIR="$(dirname "$SUDOERS_FILE")"
mkdir -p "$TARGET_DIR"

TMP_FILE="$(mktemp "${SUDOERS_FILE}.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

cat > "$TMP_FILE" <<EOF
# Managed by Atlas (mix atlas.deploy.init).
# Grants $USER_NAME passwordless sudo on the erlexec exec-port binary.
# Re-run mix atlas.deploy.init to refresh this file.
$USER_NAME ALL=(ALL) NOPASSWD: $ABS_BINARY
EOF

chmod 0440 "$TMP_FILE"

# visudo -c against the temp file first — catches syntax errors before
# we touch the real sudoers.d entry.
if ! visudo -c -f "$TMP_FILE" >/dev/null; then
  echo "$PROG: visudo validation failed on temp file; aborting" >&2
  exit 2
fi

mv "$TMP_FILE" "$SUDOERS_FILE"
trap - EXIT

# Final cross-check at the destination.
if ! visudo -c -f "$SUDOERS_FILE" >/dev/null; then
  echo "$PROG: visudo validation failed at $SUDOERS_FILE; removing" >&2
  rm -f "$SUDOERS_FILE"
  exit 2
fi

echo "$PROG: wrote $SUDOERS_FILE granting $USER_NAME sudo on $ABS_BINARY"
