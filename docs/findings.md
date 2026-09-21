# Findings

Device-specific ADB behaviour discovered on a **BLU Grand M (MT6580), Android
6.0, API 23**. Several of these contradict widely repeated debloat advice.

Each entry below is what the device reported, with the command that produced
it. Nothing here is inferred from documentation.

---

## 1. `pm disable-user` is denied, `pm uninstall` is not

The standard advice is "disable rather than uninstall, because disable is
reversible." On this device that option does not exist.

```
$ adb shell pm disable-user --user 0 com.android.calculator2
Error: java.lang.SecurityException: Permission Denial:
attempt to change component state from pid=..., uid=2000, package uid=10036
```

Every variant fails:

| Command | Result |
|---|---|
| `pm disable-user --user 0 <pkg>` | `SecurityException` |
| `pm disable-user <pkg>` | `SecurityException` |
| `pm disable <pkg>` | `SecurityException` |
| `pm hide <pkg>` | `SecurityException: MANAGE_USERS` |
| `pm uninstall --user 0 <pkg>` | **Success** |

`uid=2000` is the ADB shell user. `CHANGE_COMPONENT_ENABLED_STATE` is
signature-level and the OEM did not grant it to shell.

Root is not an escape hatch:

```
$ adb root
adbd cannot run as root in production builds
```

**Consequence:** uninstall was the only available lever, which inverted the
plan. The advice being followed assumed a capability this build does not
expose.

---

## 2. Uninstall *is* reversible — but not the documented way

`pm uninstall --user 0` on a `/system` app only unmarks it for user 0. The APK
remains physically present on the read-only `/system` partition:

```
$ adb shell pm uninstall --user 0 com.android.calculator2
Success

$ adb shell pm list packages com.android.calculator2
(nothing)

$ adb shell pm list packages -u com.android.calculator2
package:com.android.calculator2          # still known to the system

$ adb shell ls -l /system/app/Calculator/Calculator.apk
-rw-r--r-- root root 98807 2018-09-20 00:59 Calculator.apk
```

The usual restore path does not exist here:

```
$ adb shell cmd package install-existing com.android.calculator2
/system/bin/sh: cmd: not found
```

`cmd` arrived in Android 7/8. On API 23 it is absent.

**What works instead:** reinstall from the `/system` path.

```sh
adb shell "pm install -r --user 0 /system/app/Calculator/Calculator.apk"
```

---

## 3. `--user 0` is mandatory on restore, and omitting it fails silently

This is the sharpest edge in the whole exercise.

```
$ adb shell pm install -r /system/app/Calculator/Calculator.apk
        pkg: /system/app/Calculator/Calculator.apk
Success                                   # <-- lie

$ adb shell dumpsys package com.android.calculator2 | grep installed=
    User 0:  installed=false ...          # <-- not actually restored
```

With the flag:

```
$ adb shell pm install -r --user 0 /system/app/Calculator/Calculator.apk
Success

$ adb shell dumpsys package com.android.calculator2 | grep installed=
    User 0:  installed=true ...
```

`Success` without `--user 0` is a no-op. The rollback script therefore checks
`installed=`, not the exit message.

`pm enable` is denied (same `SecurityException` as above) and turned out not to
be needed: restored packages return at `enabled=0`, which is
`COMPONENT_ENABLED_STATE_DEFAULT` — enabled per manifest, not disabled.

The restored copy lands in `/data/app/` rather than `/system`, costing a little
storage. Irrelevant when storage is not the constraint.

---

## 4. `UPDATED_SYSTEM_APP` changes what uninstall actually does

`pm list packages -f` shows a `/data/app/` path for both genuine user apps and
system apps that have received updates. They behave very differently.

```sh
adb shell "dumpsys package <pkg> | grep -m1 pkgFlags="
```

Of ten packages that *looked* like ordinary user apps, only two were:

| Package | Flags |
|---|---|
| `com.whatsapp` | user app |
| `com.google.android.instantapps.supervisor` | user app |
| `com.google.android.youtube` | `SYSTEM`, `UPDATED_SYSTEM_APP` |
| `com.google.android.apps.maps` | `SYSTEM`, `UPDATED_SYSTEM_APP` |
| `com.google.android.gm` | `SYSTEM`, `UPDATED_SYSTEM_APP` |
| ... | |

For `UPDATED_SYSTEM_APP` entries, uninstalling removes the update *and* hides
the factory version for user 0. Only genuine user apps get fully removed with
storage reclaimed.

The flags were checked before the tiering was finalised, which is what moved
eight packages out of the "real uninstall" tier.

---

## 5. Removing GMS requires clearing device-admin first

```
$ adb shell pm uninstall --user 0 com.google.android.gms
Failure [DELETE_FAILED_DEVICE_POLICY_MANAGER]
```

Play Services registers itself as an active device admin:

```
$ adb shell dumpsys device_policy
Enabled Device Admins (User 0):
  com.google.android.gms/.auth.managed.admin.DeviceAdminReceiver
  com.google.android.gms/.mdm.receivers.MdmDeviceAdminReceiver
```

`dpm` exists on API 23 but only supports `set-active-admin`,
`set-device-owner`, `set-profile-owner`. There is **no `remove-active-admin`**
until Android 7, so this cannot be cleared from the shell.

It must be unchecked manually in **Settings → Security → Device
administrators**. After that the uninstall succeeds immediately.

Two things made removal low-risk here:

- `gms`, `gsf`, and `gsf.login` share `userId=10012`. Remove them as a set —
  a half-removed shared-UID group is the configuration that produces repeating
  "Play Services has stopped" dialogs.
- `dumpsys account` reported `Accounts: 0`. With no signed-in account, there
  are no sync adapters retrying against a missing service, which is the usual
  source of GMS-removal horror stories.

---

## 6. PSS accounting is broken on this build

`dumpsys meminfo` reports `0 kB` PSS for every application process:

```
    40890 kB: system (pid 994)
     8622 kB: net.ohrz.fastlauncher
        0 kB: com.google.android.gms          # <-- not actually zero
        0 kB: com.android.vending
```

and a correspondingly large accounting hole:

```
Total RAM: 470124 kB
 Free RAM: 96880 kB
 Used RAM: 124074 kB
 Lost RAM: 249170 kB      # <-- the PSS that never got attributed
```

Every before/after figure in this repo comes from `/proc/meminfo`'s
`MemAvailable` for that reason. Per-app heap figures from
`dumpsys meminfo <pkg>` (Heap Size / Heap Alloc) remained meaningful; the PSS
column did not.

---

## 7. No Play Store means split-APK installs

With `com.android.vending` removed, everything is sideloaded. APKMirror serves
`.apkm` bundles — a ZIP of split APKs, not something `adb install` accepts.

```
base.apk
split_config.armeabi_v7a.apk
split_config.arm64_v8a.apk
split_config.hdpi.apk
split_config.en.apk
...
```

Base plus the matching ABI, density and language were installed together:

```sh
adb install-multiple -r base.apk \
  split_config.armeabi_v7a.apk \
  split_config.hdpi.apk \
  split_config.en.apk
```

API 23 supports this — `pm install-create` / `install-write` / `install-commit`
are all present. An arm64-only split installs cleanly and then crashes on
launch, so the ABI was confirmed first:

```sh
unzip -l split_config.armeabi_v7a.apk | grep -oE 'lib/[a-z0-9_-]+/' | sort -u
```

The signing certificate was read without needing `apksigner`:

```sh
unzip -p base.apk 'META-INF/*.RSA' | keytool -printcert
```

---

## 8. ADB over WiFi is authenticated (contrary to common belief)

Often described as "unauthenticated." On this device it is not:

```
ro.adb.secure  = 1
ro.secure      = 1
ro.debuggable  = 0

$ adb shell "cat /data/misc/adb/adb_keys | wc -l"
1
```

`adbd` uses RSA public-key auth and it is transport-agnostic — TCP connections
are checked exactly like USB ones. A host whose key is not in
`/data/misc/adb/adb_keys` triggers the on-screen "Allow USB debugging?" prompt
and otherwise gets `unauthorized`.

The real credential turned out to be `~/.android/adbkey` on the host, not the
port.

`service.adb.tcp.port` resets on boot, so without root re-enabling it needs a
USB connection and another `adb tcpip 5555`.

---

## 9. Miscellaneous API 23 notes

- **Locale** lives in `persist.sys.locale`. `setprop` from shell failed
  silently — no error, value unchanged — so switching it needed the UI.
- **Runtime permissions** were granted headlessly — `pm grant <pkg>
  android.permission.CAMERA` — so no keyboard was needed for setup.
  `adb shell input text` also types into any focused field.
- **Permission groups**: granting storage permissions here also showed location
  as `granted=true`, which had never been requested. `dumpsys package <pkg> |
  grep granted=` caught it and `pm revoke` cleared it.
- **`find` is toybox** — no `-iname`, no `\( \)` grouping.
- **`netstat`** did not report the camera's TCP listener at all, nor did
  `/proc/net/tcp`. The server was confirmed running by connecting to it from
  another host.
- **Automatic time** was simply off. A clock 9 years and 9 months behind got
  blamed on flaky WiFi for most of a session; `auto_time` was `0`, and
  `settings put global auto_time 1` corrected it instantly.
