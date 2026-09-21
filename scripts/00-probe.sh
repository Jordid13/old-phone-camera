#!/usr/bin/env bash
#
# Capability probe. Run this FIRST, before any removal.
#
# It answers one question: what does *this* device actually permit?
# General debloat advice assumes capabilities that many OEM builds do not
# expose. Finding that out after issuing 79 commands is worse than finding it
# out now.
#
# Read-only. Nothing here changes the device.

set -uo pipefail

SERIAL="${ANDROID_SERIAL:-}"
adbs() { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

# adb consumes stdin; without </dev/null it will eat a surrounding read loop.
sh_() { adbs shell "$1" </dev/null 2>&1 | tr -d '\r'; }

hr() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

if ! command -v adb >/dev/null 2>&1; then
    echo "adb not found. brew install android-platform-tools" >&2
    exit 1
fi

n_dev=$(adb devices | grep -c "device$")
if [ "$n_dev" -eq 0 ]; then
    echo "No device. Check USB debugging is enabled and authorised." >&2
    exit 1
elif [ "$n_dev" -gt 1 ] && [ -z "$SERIAL" ]; then
    echo "Multiple devices attached. Set ANDROID_SERIAL=<serial>." >&2
    adb devices -l >&2
    exit 1
fi

hr "DEVICE"
printf '  model      %s\n' "$(sh_ 'getprop ro.product.model')"
printf '  android    %s (API %s)\n' \
    "$(sh_ 'getprop ro.build.version.release')" \
    "$(sh_ 'getprop ro.build.version.sdk')"
printf '  abi        %s\n' "$(sh_ 'getprop ro.product.cpu.abi')"
printf '  fingerprint %s\n' "$(sh_ 'getprop ro.build.fingerprint')"

hr "MEMORY (MemAvailable is the number to trust -- see findings.md #6)"
sh_ 'cat /proc/meminfo | head -3' | sed 's/^/  /'

hr "CAN SHELL DISABLE PACKAGES?"
# com.android.calculator2 is the canary: present on most builds, harmless.
# If absent the probe still reports something useful (a different error).
probe_pkg="com.android.calculator2"
if [ -z "$(sh_ "pm list packages $probe_pkg")" ]; then
    probe_pkg="$(sh_ 'pm list packages -s' | sed 's/package://' | head -1)"
fi
printf '  probing with: %s\n' "$probe_pkg"
for cmd in "pm disable-user --user 0" "pm disable" "pm hide"; do
    out=$(sh_ "$cmd $probe_pkg")
    case "$out" in
        *SecurityException*|*Permission\ Denial*) verdict="DENIED" ;;
        *new\ state*)                            verdict="PERMITTED (re-enable it!)" ;;
        *)                                       verdict="? $out" ;;
    esac
    printf '  %-28s %s\n' "$cmd" "$verdict"
done

hr "IS ROOT AVAILABLE?"
printf '  adb root       %s\n' "$(adb root 2>&1 | head -1 | tr -d '\r')"
printf '  id             %s\n' "$(sh_ 'id')"
printf '  ro.debuggable  %s\n' "$(sh_ 'getprop ro.debuggable')"
printf '  ro.secure      %s\n' "$(sh_ 'getprop ro.secure')"

hr "IS UNINSTALL REVERSIBLE?"
# 'cmd' is the documented restore path (cmd package install-existing).
# Absent before Android 7, in which case pm install -r --user 0 from the
# /system path is the fallback -- test it on a throwaway package first.
if sh_ 'which cmd' | grep -q cmd; then
    echo "  cmd present -> 'cmd package install-existing' should work"
else
    echo "  cmd NOT present (expected on API <= 23)"
    echo "  fallback: pm install -r --user 0 /system/app/<Dir>/<Name>.apk"
    echo "  NOTE: --user 0 is mandatory. Without it you get 'Success' and a"
    echo "        silent no-op. Verify with: dumpsys package <pkg> | grep installed="
fi

hr "SIM PRESENT? (absent => telephony stack is dead weight)"
printf '  gsm.sim.state  %s\n' "$(sh_ 'getprop gsm.sim.state')"

hr "GOOGLE ACCOUNTS (non-zero => GMS removal is riskier)"
sh_ 'dumpsys account 2>/dev/null | grep -m1 -i "Accounts:"' | sed 's/^/  /'

hr "ACTIVE DEVICE ADMINS (block uninstall with DELETE_FAILED_DEVICE_POLICY_MANAGER)"
admins=$(sh_ 'dumpsys device_policy' | grep "DeviceAdminReceiver:" | sed 's/^ */  /')
[ -n "$admins" ] && echo "$admins" || echo "  (none)"

hr "HARDWARE VIDEO ENCODERS (needed for a usable camera)"
enc=$(sh_ 'cat /etc/media_codecs*.xml 2>/dev/null' \
      | grep -oE 'MediaCodec name="OMX\.[A-Za-z0-9._]*(ENCODER|encoder)[A-Za-z0-9._]*"' \
      | sed 's/MediaCodec name=//; s/"//g' | sort -u)
[ -n "$enc" ] && echo "$enc" | sed 's/^/  /' || echo "  (none found)"

hr "PACKAGE COUNTS"
printf '  system       %s\n' "$(sh_ 'pm list packages -s' | grep -c package:)"
printf '  third-party  %s\n' "$(sh_ 'pm list packages -3' | grep -c package:)"

hr "SUMMARY"
cat <<'EOF'
  If "CAN SHELL DISABLE PACKAGES?" shows DENIED and root is unavailable,
  uninstall is your only lever -- and you should confirm the restore path
  on one disposable package before touching anything you care about.

  See docs/findings.md for what each of these results implies.
EOF
echo
