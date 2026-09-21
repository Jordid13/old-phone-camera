# Debloat rationale

Every package removed, with the reason. 79 packages via
`pm uninstall --user 0`, plus 2 genuine user apps, plus a launcher swap.

**This list is specific to a BLU Grand M on Android 6.0.** Package names and OEM
bloat differ by device, so it is a record of what was removed here rather than a
portable script.

Two device facts drove most of the aggression:

- **`gsm.sim.state: ABSENT`** — no SIM, so the entire telephony stack is inert
  weight rather than functionality.
- **Uninstall is reversible here** (see `findings.md` §2), so cutting deep was
  cheap to undo. The tiering below would be far more conservative otherwise.

---

## Tier A — genuine user apps (2)

In `/data/app`, not `UPDATED_SYSTEM_APP`. True removal, storage reclaimed,
reinstallable normally.

| Package | Reason |
|---|---|
| `com.whatsapp` | previous owner's, not needed |
| `com.google.android.instantapps.supervisor` | Instant Apps, unused |

Originally this tier had ten entries. Checking `pkgFlags=` showed the other
eight were `UPDATED_SYSTEM_APP` — moved to Tier C.

---

## Tier B — telephony stack (19)

No SIM present. None of this can do anything useful; all of it can wake up,
register receivers, and consume memory.

| Package | What it is |
|---|---|
| `com.google.android.apps.messaging` | Messages |
| `com.google.android.ims` | CarrierServices / RCS |
| `com.android.dialer` | Dialer |
| `com.android.contacts` | Contacts |
| `com.android.providers.contacts` | Contacts provider |
| `com.android.providers.telephony` | Telephony provider |
| `com.android.server.telecom` | Telecom |
| `com.android.mms.service` | MMS |
| `com.android.carrierconfig` | Carrier config |
| `com.android.stk` | SIM Toolkit |
| `com.android.calllogbackup` | Call log backup |
| `com.mediatek.cellbroadcastreceiver` | Emergency alerts |
| `com.mediatek.engineermodecmas` | CMAS engineering mode |
| `com.mtk.telephony` | BSP telephony dev tool |
| `com.mediatek.omacp` | Carrier provisioning |
| `org.simalliance.openmobileapi.service` | Smartcard service |
| `org.simalliance.openmobileapi.eseterminal` | Secure element |
| `org.simalliance.openmobileapi.uicc1terminal` | UICC terminal |
| `org.simalliance.openmobileapi.uicc2terminal` | UICC terminal |

**Not removed:** `com.android.phone` (TeleService). Disabling or removing it on
MediaTek is a known bootloop risk, and with no SIM it is already idle. Bad
risk/reward.

---

## Tier C — Google layer (19)

Includes the eight `UPDATED_SYSTEM_APP` entries relocated from Tier A.

| Package | What it is |
|---|---|
| `com.google.android.youtube` | YouTube |
| `com.google.android.apps.maps` | Maps |
| `com.google.android.apps.photos` | Photos |
| `com.google.android.gm` | Gmail |
| `com.google.android.apps.cloudprint` | Cloud Print |
| `com.google.android.googlequicksearchbox` | Google app / search (Velvet) |
| `com.google.android.tts` | Text-to-speech |
| `com.warranteer.helper.blu` | BLU warranty bloat |
| `com.google.android.apps.tachyon` | Duo |
| `com.google.android.calendar` | Calendar |
| `com.google.android.syncadapters.contacts` | Contacts sync |
| `com.google.android.backuptransport` | Backup transport |
| `com.google.android.feedback` | Crash reporting |
| `com.google.android.partnersetup` | Partner setup |
| `com.google.android.onetimeinitializer` | One-time init |
| `com.google.android.configupdater` | Config updater |
| `com.google.android.setupwizard` | Setup wizard (already completed) |
| `com.google.android.setupwizard.overlay` | OEM setupwizard overlay |
| `com.google.android.inputmethod.japanese` | Japanese IME |

### Play Services and Play Store

Held back initially, removed after the rest settled so any breakage would be
attributable. Removed as a set — `gms`, `gsf`, and `gsf.login` share
`userId=10012`:

| Package |
|---|
| `com.google.android.gms` |
| `com.android.vending` |
| `com.google.android.gsf` |
| `com.google.android.gsf.login` |

Requires clearing device-admin receivers first — see `findings.md` §5.

This was safe here because the camera app has no GMS dependency, nothing on the
device needs push or location, and `dumpsys account` reported zero signed-in
accounts — the usual source of post-removal breakage is sync adapters retrying
against a service that is gone.

Result: six GMS/Play processes down to zero, roughly 41 MB of Java heap
recovered.

---

## Tier D — unused apps and OEM tooling (41)

Stock apps, OEM diagnostics, and redundant components.

**Redundant browsers/viewers** — all overlap with the system WebView, which is
kept:

`com.android.chrome`, `com.opera.branding`, `com.blu.htmlviewer`

**Media and productivity** — nothing on this device plays or edits media:

`com.android.gallery3d`, `com.android.music`, `com.android.musicfx`,
`com.android.fmradio`, `com.android.email`, `com.android.exchange`,
`com.android.deskclock`, `com.android.calculator2`, `com.android.printspooler`,
`com.android.dreams.basic`

**Providers and framework extras** for features now absent:

`com.android.bookmarkprovider`, `com.android.providers.partnerbookmarks`,
`com.android.wallpapercropper`, `com.android.managedprovisioning`,
`com.android.providers.calendar`, `com.android.providers.userdictionary`,
`com.android.providers.applications`, `com.android.providers.downloads.ui`,
`com.android.backupconfirm`, `com.android.sharedstoragebackup`,
`com.android.vpndialogs`

**Bluetooth and location** — unused by a fixed, wired-power camera:

`com.android.bluetooth`, `com.android.bluetoothmidiservice`,
`com.android.location.fused`

**MediaTek diagnostics** — factory tooling with no end-user purpose:

`com.mediatek.filemanager`, `com.mediatek.mtklogger` (active logging
overhead), `com.mediatek.engineermode`, `com.mediatek.lbs.em2.ui`,
`com.mediatek.ygps`, `com.mediatek.miravision.ui`,
`com.mediatek.schpwronoff`, `com.mediatek.calendarimporter`,
`com.mediatek.bluetooth.dtt`, `com.mediatek.providers.drm`

**OEM leftovers:**

| Package | Note |
|---|---|
| `com.nextradioapp.nextradio` | preinstalled radio app |
| `com.blu.copy` | `CopyImageToSD` |
| `com.android.factory` | `BLUFactory` test app |
| `com.example` | **`/system/app/AutoDialer`** — an unsigned-looking OEM leftover under the `com.example` namespace. An auto-dialer on an always-on device is worth removing on principle. |

---

## Kept deliberately

| Package | Why |
|---|---|
| `android`, `com.mediatek`, `com.mediatek.fwk.plugin` | frameworks |
| `com.mediatek.security` | `PermissionControl` — runtime permissions |
| `com.android.shell` | ADB itself |
| `com.android.systemui` | the only recovery surface if something breaks |
| `com.android.settings`, `com.android.providers.settings` | needed for the handful of UI-only changes (locale, device admin) |
| `com.android.providers.media` | audio/video capture depends on it |
| `com.android.externalstorage`, `com.android.defcontainer` | storage plumbing |
| `com.google.android.packageinstaller` | installing the camera APK |
| `com.android.keychain`, `com.android.certinstaller` | TLS |
| `com.android.captiveportallogin` | WiFi captive portals |
| `com.android.pacprocessor`, `com.android.proxyhandler` | WiFi proxy |
| `com.mediatek.thermalmanager` | **thermal safety on a 24/7 device** |
| `com.mediatek.batterywarning` | battery safety |
| `com.google.android.inputmethod.latin` | only IME on the device |
| `com.google.android.webview` | system dependency |
| `com.android.soundrecorder` | zero-effort mic sanity check |
| `com.android.launcher3` | became the launcher after fastlauncher was removed |
| `com.mediatek.camera` | only app that can show a camera preview for aiming |

Removing an app never removes hardware capability. `com.mediatek.camera` is the
camera *app*; the HAL and `camera2` API are untouched regardless. There is no
"microphone app" to delete — `AudioRecord` is framework-level.

---

## Launcher swap

`net.ohrz.fastlauncher` was replaced by stock `com.android.launcher3` after
measurement showed the third-party "fast" launcher used more than twice the
memory (8,046 kB PSS vs 3,478 kB) and a 6.5 MB APK against 1.9 MB.

Uninstalling fastlauncher leaves Launcher3 as the only `HOME` handler, so it
takes over with no default-app picker involved.

---

## Settings changes

Not packages, but changed in the same pass:

```sh
settings put global auto_time 1                      # clock was 9y9m behind
settings put global auto_time_zone 1
settings put secure screensaver_enabled 0            # Daydream triggers while charging
settings put secure screensaver_activate_on_sleep 0
settings put secure screensaver_activate_on_dock 0
settings put system screen_off_timeout 15000         # backlight is the main power draw
```

Already correct on this device, so left alone:

```
wifi_sleep_policy         = 2   (never sleep)
stay_on_while_plugged_in  = 0   (screen still sleeps on charge)
window_animation_scale    = 0
transition_animation_scale = 0
animator_duration_scale   = 0
```
