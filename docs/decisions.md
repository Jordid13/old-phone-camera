# Decision log

Built in one session with Claude Code. This records what was believed, what
testing showed, and what changed — including the times the agent was wrong.

The corrections are the point. A log that shows only a straight line to success
is not a useful record of what working with an agent is actually like.

---

## 1. Disable vs uninstall — recommendation inverted by a capability probe

**Believed:** `pm disable-user` is the safe choice because it is reversible,
while `pm uninstall --user 0` is effectively permanent on API 23 (no `cmd`
binary, so no `cmd package install-existing`). The agent argued for disable at
some length, and the reasoning was sound in general.

**Testing showed:** `pm disable-user` is denied outright to ADB shell on this
device — `SecurityException`, uid 2000 lacks
`CHANGE_COMPONENT_ENABLED_STATE`. Every variant (`disable`, `disable-user`,
`hide`) fails. `adb root` is refused on a production build. Meanwhile
`pm uninstall --user 0` works.

**Changed:** the entire method. The only available lever was the one that had
been argued against.

**Cost:** a wasted batch of 79 failed commands. The general advice being
followed assumed a capability this build does not expose, and a two-minute
probe would have surfaced that before any of it was designed.

---

## 2. Reversibility — tested on one disposable package before committing to 79

**Problem:** uninstall appeared to be one-way. `cmd` does not exist on API 23,
so the documented restore path was unavailable. Committing 79 packages to an
irreversible operation on a device with no firmware backup is a bad trade.

**Hypothesis:** for `/system` apps, `pm uninstall --user 0` only hides the
package for user 0 — the APK is still physically on the read-only partition, so
`pm install -r` from that path might restore it.

**Test:** uninstalled `com.android.calculator2` alone — harmless, already on
the removal list, nothing depends on it — then attempted restore.

**Result:** the hypothesis held, but only with `--user 0`. Without the flag,
`pm install -r` returns `Success` and silently does nothing
(`installed=false`). That discrepancy would have been invisible if the check
had been "did the command succeed" rather than "is the package actually back."

**Changed:** uninstall was reclassified from irreversible to reversible, which
made an aggressive 79-package pass reasonable rather than reckless.

**Effect on the work:** the escape hatch got tested on something disposable
before it was needed, and every subsequent verification checked state rather
than exit codes.

---

## 3. ADB over WiFi auth — asserted without checking, then corrected

**Believed and stated:** "Port 5555 has no authentication. Anyone on your WiFi
can connect and get a full ADB shell." Offered as a caveat when enabling
`adb tcpip 5555`.

**Testing showed:**

```
ro.adb.secure = 1
authorized keys in /data/misc/adb/adb_keys: 1
```

`adbd` enforces RSA public-key authentication and does so transport-agnostically
— TCP is checked exactly like USB. An unknown host gets the on-screen "Allow USB
debugging?" prompt and `unauthorized` otherwise. The earlier silent reconnect
succeeded because the host key was already trusted, not because auth was absent.

**Changed:** the claim was wrong and was retracted. The actual credential is
`~/.android/adbkey` on the host; a password would have been a *downgrade* from
key auth.

**Note:** the assertion was plausible, commonly repeated, and false. It
survived until it was questioned directly — nothing about the claim itself
signalled that it had never been checked.

---

## 4. Clock 9 years behind — misdiagnosed as a network problem

**Believed:** the device clock (Dec 2016, actual Sep 2026) would self-correct
via NTP once WiFi held a stable connection. This was repeated across several
exchanges as "still blocked on the network."

**Testing showed:**

```
auto_time      = 0
auto_time_zone = 0
```

Automatic time sync was simply disabled. It was never a network issue.

**Changed:** one settings write plus a WiFi bounce, and the clock matched the
Mac to the second.

**Note:** an unverified causal story survived several turns because it was
consistent with other symptoms — the WiFi genuinely *was* flaky. Correlation
made the wrong diagnosis feel confirmed. Checking the setting took ten seconds
and happened only when asked about directly.

---

## 5. Audio classification → camera

**Original design:** phone as dumb network mic → audio chunks over WiFi → Mac
runs YAMNet → fine-tune a classifier on 20–50 samples of the dog's specific
whine → threshold + 60s debounce → ntfy.sh push.

**Reconsidered because:** that pipeline needs a model, labeled training data
collected by hand, threshold tuning, and debounce logic — and after all of it
the output is still a probabilistic *maybe something happened*. Acting on it
means going to look anyway.

**Changed to:** a camera. No model, no training data, no false positives.

**Supporting evidence:** the phone has `OMX.MTK.VIDEO.ENCODER.AVC` in hardware,
measured at 50–100 fps at 720x480 against a need for 15–20. The task it was
*bad* at (inference, which is why it was offloaded to a Mac in the first place)
was the task that got eliminated.

**Note:** the simpler tool answered the real question better, and the hard
problem turned out not to be the necessary one.

---

## 6. Bandwidth reasoning that did not transfer

**Stated during the audio design:** "capacity is a non-issue" — 16 kHz mono
16-bit PCM is 256 kbps, and even a bad link carries multiple Mbps. The problem
was framed as connection *stability*, not throughput, and mitigations were
scoped accordingly (ring buffer, reconnect logic).

**After the pivot:** that reasoning does not carry over. H.264 at
720x480/15fps is roughly 0.5–1.5 Mbps and MJPEG considerably more — 2–6x the
audio figure, on a 2.4 GHz single-antenna radio at -75 dBm.

**Changed:** bandwidth moved from "non-issue" back to "open question, test in
place." Measured later at ~124 KB/s and 8.5 fps over MJPEG, which is adequate.

**Note:** a conclusion derived under one set of requirements got carried
forward as established fact after the requirements changed. Re-deriving it put
bandwidth back on the open-questions list.

---

## 7. Launcher choice — measured rather than assumed

**Believed:** `net.ohrz.fastlauncher`, already installed, was the lightweight
option. The name implies it.

**Measured:**

| | fastlauncher | Launcher3 (stock) |
|---|---:|---:|
| PSS (foreground) | 8,046 kB | **3,478 kB** |
| Dalvik heap alloc | 14,607 kB | **5,731 kB** |
| APK size | 6.5 MB | **1.9 MB** |

**Changed:** switched to stock Launcher3 and removed fastlauncher, dropping
third-party package count to zero.

**Honest caveat recorded at the time:** in the deployed configuration this
barely matters. Backgrounded, fastlauncher dropped to 792 kB and would be killed
under pressure anyway. The real gain was one less third-party component running
unattended, not the 4.5 MB.

---

## Operator notes

Things the human did that shaped the outcome, and that are invisible from the
artifacts alone:

- **Separated research from action.** "Before you even make the scope don't
  guess it, do a discovery (read only) of what we could remove and then give the
  actual scope." This forced enumeration before planning and is how the tiering
  ended up defensible rather than vibes-based.
- **Interrupted when the agent moved faster than understanding.** More than once,
  with "just do read actions for now, let's get familiar with the device."
- **Ran the destructive commands personally.** The bulk `pm uninstall` loop was
  executed by the operator rather than granting the agent blanket permission.
- **Questioned a confident claim**, which is what surfaced the ADB auth error in
  §3. The agent would not have caught it unprompted.

## What was deliberately not delegated

- Typing the stream password — done by hand.
- Approving each irreversible batch.
- The physical decisions: placement, mounting, network topology.
- Judging whether the pivot was worth it. The agent laid out the tradeoff; the
  call was the operator's.
