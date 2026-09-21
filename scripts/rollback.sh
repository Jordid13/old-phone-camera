#!/usr/bin/env bash
#
# Restore everything 01-debloat.sh removed.
#
# Works because `pm uninstall --user 0` on a /system app only unmarks it for
# user 0 -- the APK is still physically present on the read-only /system
# partition, so it can be reinstalled from there.
#
#   pm install -r --user 0 /system/app/Calculator/Calculator.apk
#                 ^^^^^^^^
# --user 0 IS MANDATORY. Without it pm reports "Success" and does nothing
# (installed=false). See docs/findings.md section 3.
#
# packages/restore-map.txt is "<package> <absolute /system apk path>", one per
# line. Regenerate it for your device with --regenerate before you need it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
MAP="$ROOT/packages/restore-map.txt"

SERIAL="${ANDROID_SERIAL:-}"
adbs() { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@"; else adb "$@"; fi; }

n_dev=$(adb devices | grep -c "device$")
if [ "$n_dev" -eq 0 ]; then
    echo "No device attached." >&2; exit 1
elif [ "$n_dev" -gt 1 ] && [ -z "$SERIAL" ]; then
    echo "Multiple devices. Set ANDROID_SERIAL=<serial>." >&2; exit 1
fi

# --------------------------------------------------------------------------
# Rebuild the package -> /system APK map from the device itself.
# Run this BEFORE debloating: once a package is uninstalled, dumpsys no longer
# reports its codePath, so the map cannot be reconstructed afterwards.
# --------------------------------------------------------------------------
if [ "${1:-}" = "--regenerate" ]; then
    LIST="${2:-$ROOT/packages/remove.txt}"
    [ -f "$LIST" ] || { echo "No list at $LIST" >&2; exit 1; }
    echo "Regenerating restore map from device..."

    PKGS=$(grep -ve '^\s*$' -e '^\s*#' "$LIST" | tr '\n' ' ')

    adbs shell "for p in $PKGS; do echo \"PKG=\$p\"; \
        dumpsys package \$p 2>/dev/null | grep -oE 'codePath=[^ ]+|resourcePath=[^ ]+'; done" \
        </dev/null 2>&1 | tr -d '\r' > /tmp/rb-paths.txt

    # Keep only /system or /vendor paths. A package with a /data/app path is an
    # UPDATED_SYSTEM_APP whose update will be deleted -- we need the factory one.
    awk '/^PKG=/{p=substr($0,5); next}
         /=\/(system|vendor)/{v=substr($0,index($0,"=")+1); print p, v}' \
        /tmp/rb-paths.txt | sort -u -k1,1 > /tmp/rb-dirs.txt

    adbs shell "ls /system/app/*/*.apk /system/priv-app/*/*.apk /vendor/overlay/*/*.apk 2>/dev/null" \
        </dev/null 2>&1 | tr -d '\r' \
        | sed 's|\(.*\)/[^/]*\.apk$|\1\t&|' > /tmp/rb-apks.tsv

    awk 'NR==FNR{split($0,a,"\t"); apk[a[1]]=a[2]; next}
         {print $1, (apk[$2]!="" ? apk[$2] : "NOTFOUND")}' \
        /tmp/rb-apks.tsv /tmp/rb-dirs.txt > "$MAP"

    total=$(wc -l < "$MAP" | tr -d ' ')
    missing=$(grep -c NOTFOUND "$MAP" || true)
    echo "  wrote $MAP ($total entries, $missing unresolved)"
    [ "$missing" -gt 0 ] && grep NOTFOUND "$MAP" | sed 's/^/    /'
    exit 0
fi

[ -f "$MAP" ] || {
    echo "No restore map at $MAP" >&2
    echo "Generate it BEFORE debloating:  $0 --regenerate" >&2
    exit 1
}

if grep -q NOTFOUND "$MAP"; then
    echo "Restore map has unresolved entries; these cannot be restored:" >&2
    grep NOTFOUND "$MAP" | sed 's/^/  /' >&2
    echo
fi

COUNT=$(grep -vc NOTFOUND "$MAP" || true)
echo
echo "  Restoring $COUNT packages from /system."
read -r -p "  Type 'yes' to proceed: " reply
[ "$reply" = "yes" ] || { echo "  Aborted."; exit 0; }
echo

ok=0; bad=0
while read -r pkg apk; do
    [ "$apk" = "NOTFOUND" ] && continue
    out=$(adbs shell "pm install -r --user 0 $apk" </dev/null 2>&1 | tr -d '\r')
    if echo "$out" | grep -q Success; then
        # Verify state rather than trusting the exit message -- see findings #3.
        st=$(adbs shell "dumpsys package $pkg | grep -m1 installed=" </dev/null 2>&1 | tr -d '\r')
        case "$st" in
            *installed=true*) printf '  ok      %s\n' "$pkg"; ok=$((ok+1)) ;;
            *) printf '  NO-OP   %s (Success but installed=false)\n' "$pkg"; bad=$((bad+1)) ;;
        esac
    else
        printf '  FAILED  %s :: %s\n' "$pkg" "$out"; bad=$((bad+1))
    fi
done < "$MAP"

echo
echo "  restored: $ok"
echo "  problems: $bad"
echo "  Reboot to return to a clean state."
echo
