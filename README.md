Disclaimer: This is a side passion project largely developed using AI, if there are are any script errors or wrong statements feel free to let me know as they could've slipped through my scans.

# old-phone-camera

A dead 2016 budget Android phone, stripped down and turned into a LAN security
camera in a single session with [Claude Code](https://claude.com/claude-code).

82 packages removed. MemAvailable went from 159 MB to 254 MB on a device with
470 MB total. Along the way the standard debloat advice turned out to be wrong
for this hardware, in a way that took a controlled experiment to establish.

[`docs/decisions.md`](docs/decisions.md) is the log of what was assumed, what
testing disproved, and what changed as a result.

---

## The pivot

The original build was an audio detector: phone as a dumb network microphone,
streaming to a Mac running YAMNet, fine-tuned on 20–50 hand-labelled samples of
one dog's specific whine, with a confidence threshold and a 60-second debounce
feeding a push notification.

That got scrapped before any of it was written.

The pipeline needed a model, training data collected by hand, threshold tuning,
and debounce logic — and the output would still have been a probabilistic *maybe
something happened*, which means going to look anyway. A camera answers the
question directly.

The phone turned out to have a hardware H.264 encoder with roughly 5x more
throughput than video needs. The task it was bad at — inference, which is why it
was being offloaded to a Mac in the first place — was the task that got deleted.

---

## Results

Measured before, and again after a reboot:

| | Before | After |
|---|---:|---:|
| System packages enabled | 113 | **31** |
| Third-party packages | 3 | **1** |
| MemAvailable | 159,808 kB | **254,112 kB** (+59%) |
| Free RAM | 96,880 kB | 126,792 kB |
| ZRAM swap in use | 46,448 kB | **2,560 kB** (−94%) |
| Crashes / ANRs across 3 reboots | — | **0** |

The ZRAM figure is the one that mattered. Beforehand the kernel was compressing
46 MB of pages to stay afloat on a 470 MB device. Afterwards it sat essentially
idle — the machine stopped fighting for memory, which counts for more under a
24/7 video stream than the headline number does.

---

## The hardware

| | |
|---|---|
| Device | BLU Grand M (G070Q) |
| SoC | MediaTek MT6580, quad-core Cortex-A7 @ 1.3 GHz |
| RAM | 512 MB (470 MB usable) |
| OS | Android 6.0 Marshmallow, API 23 |
| ABI | `armeabi-v7a` (32-bit only) |
| Display | 480x854 LCD |
| WiFi | 2.4 GHz only (`ro.wlan.mtk.wifi.5g = 0`) |

Whether this was viable at all came down to one file:

```xml
<MediaCodec name="OMX.MTK.VIDEO.ENCODER.AVC" type="video/avc">
    <Limit name="size" min="64x64" max="720x480" />

measured-frame-rate-320x240  range="200-300"
measured-frame-rate-720x480  range="50-100"
```

50–100 fps measured at 720x480, against a need for 15–20, on fixed-function
silicon that barely involves the CPU. Capped at 720x480, so not an HD camera —
fine for watching a doorway.

The panel is LCD rather than OLED, established by the presence of
`/sys/class/leds/lcd-backlight/`, which OLED devices don't have. That killed the
idea of a black wallpaper saving power: the backlight is uniformly lit
regardless of content. Screen-off turned out to be the only real power lever,
and it was free.

---

## What got built

The phone runs [IP Webcam](https://play.google.com/store/apps/details?id=com.pas.webcam)
(`com.pas.webcam`), serving MJPEG/H.264/RTSP over HTTP as a foreground service.
Digest auth on the stream. No cloud, no account, no port forwarding — viewed
from a browser on the LAN.

It was chosen largely by elimination. Cloud camera apps like Alfred require
Google Play Services, which had been removed. Termux, the other obvious route,
needs Android 7+ on current builds and only runs here as an unsupported legacy
version — not something to leave unattended for months.

With no Play Store on the device, installation meant sideloading. APKMirror
serves `.apkm` bundles rather than plain APKs, so the install became:

```sh
adb install-multiple -r base.apk \
  split_config.armeabi_v7a.apk \
  split_config.hdpi.apk \
  split_config.en.apk
```

The signing certificate was checked first, without needing `apksigner`:

```sh
$ unzip -p base.apk 'META-INF/*.RSA' | keytool -printcert
Owner: CN=Pas XL, O=Home, L=Moscow, ST=Russia, C=RU
SHA256: 29:C6:21:6D:B1:58:F5:1E:36:59:3B:23:94:A2:3B:FD:...
```

and the ABI confirmed, since an arm64-only split installs cleanly and then
crashes on launch:

```sh
$ unzip -l split_config.armeabi_v7a.apk | grep -oE 'lib/[a-z0-9_-]+/' | sort -u
lib/armeabi-v7a/
```

Runtime permissions were granted over ADB rather than through the UI —
`CAMERA`, `RECORD_AUDIO`, storage — and location was revoked after it turned out
to have been granted as a permission-group side effect.

Starting the server needed the screen: `.Rolling` isn't an exported activity, so
`am start` returns `SecurityException`. That step was driven with `screencap`
and `input tap` instead.

---

## The finding that reversed the plan

The accepted advice is to disable packages rather than uninstall them, because
disable is reversible. The plan followed it, and argued for it at some length.

On this device it doesn't work:

```
$ adb shell pm disable-user --user 0 com.android.calculator2
Error: java.lang.SecurityException: Permission Denial:
attempt to change component state from pid=..., uid=2000, package uid=10036
```

Every variant fails — `disable`, `disable-user`, `hide` — because shell (uid
2000) lacks `CHANGE_COMPONENT_ENABLED_STATE`. `adb root` is refused on a
production build. Meanwhile `pm uninstall --user 0` works fine.

So the only available lever was the one that had been argued against, and the
open question became whether it could be undone. The documented restore path
doesn't exist on API 23:

```
$ adb shell cmd package install-existing com.android.calculator2
/system/bin/sh: cmd: not found
```

The hypothesis was that uninstalling a `/system` app only hides it for user 0,
leaving the APK on the read-only partition. `com.android.calculator2` was
uninstalled alone to test it — harmless, already on the removal list, nothing
depending on it:

```
$ adb shell ls -l /system/app/Calculator/Calculator.apk
-rw-r--r-- root root 98807 2018-09-20 00:59 Calculator.apk   # still there
```

It restored. But only with `--user 0`:

```
$ adb shell pm install -r /system/app/Calculator/Calculator.apk
Success                                    # <- a lie

$ adb shell dumpsys package com.android.calculator2 | grep installed=
    User 0:  installed=false               # <- not restored

$ adb shell pm install -r --user 0 /system/app/Calculator/Calculator.apk
Success

$ adb shell dumpsys package com.android.calculator2 | grep installed=
    User 0:  installed=true
```

`Success` without the flag is a silent no-op. Checking "did the command
succeed" rather than "is the package actually back" would have produced a
rollback script that reported success and restored nothing.

With the escape hatch confirmed on one disposable package, removing 79 became
reasonable rather than reckless.

Full detail in [`docs/findings.md`](docs/findings.md), which also covers the
`UPDATED_SYSTEM_APP` distinction, GMS device-admin blocking, and the fact that
PSS accounting is broken on this build (`dumpsys meminfo` reports `0 kB` for
every app process and a 249 MB "Lost RAM" hole, which is why `MemAvailable` is
the number quoted above).

---

## Repo contents

```
docs/findings.md            9 device-specific ADB discoveries, with the
                            commands and output that established each one
docs/decisions.md           the decision log, corrections included
docs/debloat-rationale.md   all 82 packages, tiered, with reasons, plus
                            what was deliberately kept
scripts/00-probe.sh         read-only capability probe
scripts/01-debloat.sh       the removal pass
scripts/rollback.sh         restores from /system, verifies installed=true
packages/                   the list, and the package -> APK path map
```

`packages/remove.txt` is specific to a BLU Grand M on Android 6. The reasoning
behind every entry is in `docs/debloat-rationale.md`; the probe script reports
what a given device actually permits, which is the step this project would have
saved time by running first.

---

## Built with Claude Code

The agent enumerated all 117 installed packages and sorted them into tiers with
stated reasons, probed `pm` capabilities before designing around them, ran the
single-package reversibility experiment, verified the APK signature and ABI, and
drove the phone UI over `screencap` and `input tap` where ADB couldn't reach.

It was also confidently wrong four times — about disable-vs-uninstall, about
ADB-over-WiFi authentication, about the cause of a clock nine years behind, and
about whether this repo contained a LAN IP. Each is written up in
[`docs/decisions.md`](docs/decisions.md) with what disproved it.

---

## Known gaps

IP Webcam holds `RECEIVE_BOOT_COMPLETED` but this build exposes no autostart
toggle, so a reboot takes the camera down silently. The intended fix is a
watchdog polling `/shot.jpg` from the Mac — not built.

Night performance is untested; there's no IR illuminator, and the flash sits
against a ten-year-old battery, so continuous torch was ruled out as a heat
risk. Long-run thermals are unmeasured. ADB over WiFi doesn't survive a reboot
on API 23 without root.

---

## License

MIT
