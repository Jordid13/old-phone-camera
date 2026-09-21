#!/usr/bin/env bash
#
# Remove the packages listed in packages/remove.txt via pm uninstall --user 0.
#
# BEFORE RUNNING:
#   1. ./scripts/00-probe.sh          -- confirm what your device permits
#   2. Read docs/debloat-rationale.md -- the list is device-specific
#   3. Confirm rollback.sh has a valid restore path for your device
#
# This list was built for a BLU Grand M on Android 6.0. Running it unmodified
# on different hardware will remove the wrong things.
#
# Uninstall here is reversible ONLY because the APKs remain on the read-only
# /system partition. See docs/findings.md sections 2 and 3.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
LIST="${1:-$ROOT/packages/remove.txt}"

SERIAL="${ANDROID_SERIAL:-}"
adbs() { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

[ -f "$LIST" ] || { echo "No package list at $LIST" >&2; exit 1; }

n_dev=$(adb devices | grep -c "device$")
if [ "$n_dev" -eq 0 ]; then
    echo "No device attached." >&2; exit 1
elif [ "$n_dev" -gt 1 ] && [ -z "$SERIAL" ]; then
    echo "Multiple devices. Set ANDROID_SERIAL=<serial>." >&2; exit 1
fi

COUNT=$(grep -cve '^\s*$' -e '^\s*#' "$LIST")
MODEL=$(adbs shell getprop ro.product.model </dev/null 2>&1 | tr -d '\r')
API=$(adbs shell getprop ro.build.version.sdk </dev/null 2>&1 | tr -d '\r')

cat <<EOF

  Device : $MODEL (API $API)
  List   : $LIST
  Packages to remove: $COUNT

  This uninstalls for user 0. Restore with scripts/rollback.sh.
EOF

read -r -p "  Type 'yes' to proceed: " reply
[ "$reply" = "yes" ] || { echo "  Aborted."; exit 0; }

BEFORE=$(adbs shell "grep MemAvailable /proc/meminfo" </dev/null 2>&1 | tr -d '\r' | tr -s ' ')
echo "  before: $BEFORE"
echo

# One batched adb invocation rather than N round-trips. On a slow USB link
# 79 sequential `adb shell` calls take minutes; batched it takes seconds.
PKGS=$(grep -ve '^\s*$' -e '^\s*#' "$LIST" | tr '\n' ' ')

adbs shell "for p in $PKGS; do printf '%s ' \$p; pm uninstall --user 0 \$p; done" \
    </dev/null 2>&1 | tr -d '\r' | tee /tmp/debloat-result.txt

ok=$(grep -c 'Success' /tmp/debloat-result.txt || true)
bad=$(grep -ci 'failure\|error' /tmp/debloat-result.txt || true)

echo
echo "  succeeded: $ok"
echo "  failed:    $bad"
[ "$bad" -gt 0 ] && grep -i 'failure\|error' /tmp/debloat-result.txt | sed 's/^/    /'

cat <<'EOF'

  DELETE_FAILED_DEVICE_POLICY_MANAGER means the package is an active device
  admin. Clear it in Settings > Security > Device administrators, then retry.
  API 23's dpm has no remove-active-admin, so this cannot be scripted.

  Reboot before measuring. The process table still holds pre-removal state.
EOF
echo
