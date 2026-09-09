![fanctl banner: pixel-art Mac mini with a glowing cyan fan, the word fanctl, and a stepped fan curve chart](assets/banner.png)

# macos-fan-control — `fanctl`

**A temperature-driven fan controller for macOS: a tiny C daemon that follows a fan curve you define, plus a menu bar app so it is never running invisibly.** Built for Apple Silicon (developed on an M4 Mac mini) and works on Intel Macs too.

[![build](https://github.com/beomwookang/macos-fan-control/actions/workflows/build.yml/badge.svg)](https://github.com/beomwookang/macos-fan-control/actions/workflows/build.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)](#requirements)
[![Language](https://img.shields.io/badge/C-IOKit%20only-blue)](src/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Apple's own thermostat lets an Apple Silicon Mac sit at 90–100 °C with the fan barely turning. That is intentional — quiet beats cool, and the chip is within spec. If you would rather trade a little noise for a much cooler machine, or if some other tool has left your fan stuck at one speed, this fixes both.

---

## Why this exists

If you have ever set a manual fan speed in a GUI tool and then wondered why your Mac runs hot forever after, here is what happened.

Writing a manual RPM **latches** it into the SMC as `F0Md=1` (manual mode) plus `F0Tg=<value>` (target RPM). Quitting the app does not clear it. Removing its privileged helper does not clear it either. The fan is now nailed to that number no matter how hot the machine gets.

Measured on an M4 Mac mini: with `F0Md=1, F0Tg=1000` left behind, a 10-core load pushed the die to **82.8 °C and the fan never moved off 1000 RPM.** "It's hot but the fan won't spin up" is not a hardware fault — it is that latch.

`fanctl` replaces the latch with an actual temperature-driven curve. And in the lowest curve step it deliberately writes `F0Md=0`, handing control back to the SMC, so that if the daemon is killed the machine falls back to Apple's thermostat instead of staying pinned.

## What you get

| Piece | What it does |
| --- | --- |
| `fanctl` daemon | The controller. One long-lived IOKit connection, a handful of SMC reads per poll. Runs under `launchd`. |
| `fanctl` CLI | `status`, `temps`, `pause`, `resume`, `force`, `auto`, `selftest`, `dump`, and a JSON mode for scripting. |
| `Fanctl.app` | Menu bar app: live temperature and RPM, on/off, presets, a settings window, login-item toggle. |

No network access, no telemetry, no auto-updater, no external dependencies. Two binaries totalling well under a megabyte.

## Requirements

| | |
| --- | --- |
| macOS | 13 (Ventura) or newer |
| Hardware | Apple Silicon or Intel Mac. Every fan the machine reports is managed |
| To build | Xcode Command Line Tools — `xcode-select --install` |

## Install

```sh
git clone https://github.com/beomwookang/macos-fan-control.git
cd macos-fan-control
make
sudo ./install.sh
```

Then open the menu bar app:

```sh
open -a /Applications/Fanctl.app
```

**Build it on the machine you are installing it on.** Do not copy a prebuilt `Fanctl.app` from another Mac — the bundle is ad-hoc signed, so a transferred copy picks up a quarantine flag and macOS refuses to launch it. A locally built bundle has no such flag. `install.sh` builds for you if `build/` is missing.

During install, `fanctl selftest` runs to find out which control method actually works on your model. **Your fan gets loud for about 30 seconds.** That is the test, not a malfunction.

<details>
<summary>What <code>install.sh</code> does, step by step</summary>

1. Checks for other fan tools (Macs Fan Control, smcFanControl, TG Pro) **and their privileged helpers** — killing only the GUI leaves the helper holding the SMC keys. Offers to shut them down.
2. Runs `fanctl selftest`, which writes to the SMC and then waits up to 14 seconds to see whether `F0Ac` (measured RPM) actually follows. It sets `mode` in your config from the result.
3. Installs the binary, config, `launchd` daemon, log rotation, the menu bar app, a root helper, and a `sudoers` rule scoped to that helper alone.

</details>

## Quick start

```sh
fanctl status          # temperature, fan, mode, and where you are on the curve
fanctl temps           # every monitored sensor
tail -f /usr/local/var/log/fanctl.log

sudo fanctl pause      # hand the fan back to macOS, leave the daemon running
sudo fanctl resume

fanctl -n -v daemon    # dry run: decide and log, never touch the fan. Use this to tune.

sudo fanctl calibrate  # measure this machine and suggest a curve (~6 min, loud)
```

`fanctl status` looks like this:

```
temp      58.7 C control (family mean of 18 sensors), 61.8 C peak @Tp0Z
fan       1401 rpm actual, 1400 rpm target
limits    min 1000 / max 4900 rpm
smc mode  forced (F0Md=1) - fan pinned at target
fanctl    force mode
curve     0C:1000 58C:1400* 65C:1800 71C:2300 77C:2900 83C:3600 89C:4300 95C:4900
```

## The menu bar app

Open `Fanctl.app` and a fan icon appears in the menu bar. It stays there while the daemon runs, and **if the icon is gone, fan control is off.** A tool quietly pinning your fan is the problem this project exists to solve, so that correspondence has to hold.

### In the bar

A drawn mark, then temperature over RPM on two short lines in monospaced digits,
so the item stays narrow and does not shuffle sideways as the numbers change.

Both halves of the mark carry a value rather than decorating: the fan's ring
fills clockwise with RPM and its blades advance further between refreshes the
faster it turns, while the thermometer's column rises and reddens with
temperature. The whole mark dims when control is off. A glance answers the same
question as reading the numbers, for the times you are not reading them.

The temperature colour has two steps, both derived from the config's own
`critical_temp` rather than from hardcoded numbers — orange 20 °C below it, red
8 °C below it — so they follow if you change that setting.

### In the menu

| Item | What it does |
| --- | --- |
| Status panel | The current reading, the peak and which sensor it came from, a temperature sparkline over the last few minutes, and a bar showing how much of the fan's range is in use — with a tick at the RPM the curve is asking for while a ramp is still climbing to it. Refreshes every 3 s, including while the menu is open |
| Fan control on / off | `fanctl pause` / `resume`. Off means macOS takes over. |
| Presets | Quiet / Balanced / Cool |
| Settings… | A draggable curve graph with a live marker. The nine response parameters sit behind an Advanced disclosure, each with a note on what it trades |
| Start at login | Toggles a `LaunchAgent` in `~/Library/LaunchAgents` |
| Start daemon at boot | `launchctl enable` / `disable` |
| Quit | **Stops the daemon too, and hands the fan back to macOS** |

The app has no privilege of its own. Everything needing root goes through `/usr/local/libexec/fanctl-admin`, and the `sudoers` rule permits **only that one script** without a password. The real security boundary is therefore the verb list inside the script, not `sudoers` — which is why no branch in it passes caller input to a shell.

Saving settings rewrites **only the lines whose values changed**, so the commentary in your config file survives. The new config is parsed with `fanctl -c <tmpfile> status` before it is installed, so a curve the daemon would reject never reaches the live file.

## Tuning the fan curve

The easiest way is to drag it: **Settings…** in the menu bar opens a graph with
a draggable point per curve step, and a live marker showing where the machine
currently sits on it. The marker takes the same colour as the menu bar reading —
grey when the temperature is unremarkable, orange when warm, red when close to
`critical_temp`.

If you would rather not guess at the numbers at all, measure them:

```sh
sudo fanctl calibrate        # cap the die at 80 C (the default)
sudo fanctl calibrate 75     # or wherever you want it capped
```

This runs an all-core load and holds the fan at a series of fixed speeds,
recording where the temperature actually settles at each. It takes about six
minutes, the machine is hot and loud throughout, and it pauses the daemon while
it works. What comes back is what each temperature actually costs on *your*
machine, plus a curve line ready to paste:

```
Equilibrium under full load:
   1000 rpm  ->  89.4 C
   1975 rpm  ->  79.1 C
   2950 rpm  ->  72.6 C
   3925 rpm  ->  68.2 C
   4900 rpm  ->  65.9 C

RPM needed to hold a given temperature:
   85 C   1443 rpm
   80 C   1889 rpm
   75 C   2610 rpm
   70 C   3550 rpm
```

Why it reports it that way round: the measured locus *falls* as RPM rises,
while a fan curve *rises* with temperature, so the two cross exactly once — and
that crossing is where the machine will really sit. The useful question is
therefore not what the curve should look like, but what RPM holds the
temperature you asked for.

### Editing it by hand

The `curve` line in `/usr/local/etc/fanctl.conf` is the whole story — `temperature:RPM` pairs in ascending order:

```
curve = 0:1000, 58:1400, 65:1800, 71:2300, 77:2900, 83:3600, 89:4300, 95:4900
```

Perceived loudness on an M4 mini: 1000 silent · 1400–1800 barely audible · 2300–2900 audible · 3600 obvious · 4300–4900 loud. Your model's numbers will differ; `max_rpm` is automatically clamped down to the hardware `F0Mx` value.

Before committing a change, run `fanctl -n -v daemon` for a few minutes and watch each decision. `avg` is what feeds the curve, `peak` is the raw maximum:

```
avg=77.6 ctrl=80.5 peak=87.4@Tp3X level=4 rpm=2900
```

Edit the file and the daemon reloads within 30 seconds. To apply immediately: `sudo launchctl kill -HUP system/com.local.fanctl`.

## How it keeps the fan from spiking

This is the part that took the most work, and it is the main reason to use this over a fixed-RPM tool.

The curve is a step function, and on the way up the controller jumps straight to the final step rather than walking through the intermediate ones. So one short burst of load can ask for `1400 → 3600`. Write that to `F0Tg` in a single go and the fan accelerates as hard as it physically can — and the ear is far more sensitive to *rate of change* than to absolute RPM. That acceleration is what you notice.

Three layers stop it:

1. **`alpha_up`** (default `0.20`) — exponential smoothing, ~15 s rise time constant, so momentary spikes move the average less.
2. **`up_delay`** (default `8` s) — a step up must stay justified for this long. Short bursts never make it through at all.
3. **`slew_up` / `slew_down`** (default `200` / `120` RPM per second) — a hard rate limit on the command itself, regardless of how far the target jumped.

While ramping, the daemon writes every 0.5 s instead of every poll. At a 3 s poll a 200 RPM/s limit still lands as 600 RPM stairs, which is audible in its own right. The EWMA weight is rescaled by elapsed time, so ticking faster does not change the smoothing constant you configured.

Measured, idle, `1000 → 2900`:

```
22:48:07  step 1 -> 1601 rpm (ramping)
          1702 → 1803 → 1905 → 2006 → 2107 → 2208 → 2309 → 2410 → 2511 → 2613 → 2713 → 2815
22:48:14  step 1 -> 2900 rpm            7.5 s to arrive
```

Crossing `critical_temp` bypasses all three layers and goes straight to maximum.

## How it works

### What the SMC fan keys actually do

Measured on a Mac mini M4 (Mac16,10), macOS 26.2:

| Key | Behaviour |
| --- | --- |
| `F0Md` | Writable. `1` = manual, `0` = SMC automatic |
| `F0Tg` | An *input* only while `F0Md=1`. When `F0Md=0` it is the SMC's own output and writing it does nothing |
| `F0Mn` | **Read-only on this model** — the SMC rejects writes with result `0x86` |
| `F0Ac` | Measured RPM (read) |

Two things matter more than the rest.

**SMC writes are asynchronous.** Read a key back immediately after writing and you still get the old value; the new one shows up about a second later. So write confirmation polls briefly instead of reading once. Not knowing this made an early version misdiagnose correct behaviour as "another app overwrote us".

**`F0Md=1` has to land before `F0Tg` is written.** Reverse the order and the write reports success while the value never changes.

### Three control modes

- **`force`** — `F0Md=1` + `F0Tg`, pinned exactly. The same mechanism Macs Fan Control uses. On models where `F0Mn` is read-only, this is the only option.
- **`floor`** — raise `F0Mn` (minimum RPM) and leave the decision to the SMC. Safer, but only available where `F0Mn` is writable.
- **`auto`** (default) — at startup, try writing `F0Mn`; use `floor` if it takes, `force` if not. One config file works on both kinds of machine.

### Why the raw temperature is not used directly

Apple Silicon core-die sensors spike more than 20 °C for a few hundred milliseconds on any momentary burst. Measured at idle on this machine:

| Aggregation | Mean | Std dev | Range |
| --- | --- | --- | --- |
| Hottest single sensor (`max`) | 55.4 | 8.74 | 25.1 |
| Max of per-family means (`mean`, default) | 52.7 | 6.65 | 18.2 |
| GPU sensors | 42.8 | 0.25 | 0.8 |

What a fan can actually change is the bulk die and heatsink temperature, and that moves on a timescale of tens of seconds. So decisions come from the smoothed value. `critical_temp` is the exception — it is judged on the raw, unsmoothed maximum.

### Overhead

- **0.017 % CPU** (0.05 s per 290 s, 3 s poll, 18 sensors)
- **4.6 MB RSS**
- 18–22 SMC reads per poll. Key metadata is cached at startup and one AppleSMC connection is held open — no repeated process spawning, no shelling out to `smctemp`.
- The fan is written only when the target RPM actually changes; during a ramp, every 0.5 s until it arrives.
- The menu bar app spawns one `fanctl -j status` every 3 s. State that needs `sudo` is read only when the menu opens or right after an action.

### Safety

- `critical_temp` (default 98 °C) — raw peak above this ignores the curve and the slew limits, and goes to maximum.
- Three consecutive sensor read failures hand the fan back to macOS.
- `SIGTERM` / `SIGINT` restore `F0Md=0`.
- The lowest curve step runs at `F0Md=0` on purpose, so an unclean death leaves the machine on Apple's thermostat rather than pinned at minimum. Dying at a higher step leaves the fan loud, which is merely annoying rather than dangerous.
- `max_rpm` is clamped to the hardware `F0Mx` value.
- `launchd` `KeepAlive` restarts the daemon within 10 s.
- A malformed config line is ignored individually; the previous value stays.

## Macs with more than one fan

All of them are managed. The fan count comes from `FNum`, the SMC's own, with
probing as a fallback where it is missing — so 14"/16" MacBook Pros, iMacs and
the Mac Pro get every fan driven rather than just the first.

One curve applies to the whole set, with each fan clamped to its own `F<N>Mx`:
a smaller fan should not be asked for RPM it cannot reach, and a larger one
should not be held back by a smaller sibling. `fanctl status` lists them
individually once there is more than one.

To manage only some of them, list the indices in the config:

```
fans = 0,1
```

## fanctl vs other macOS fan control tools

|  | fanctl | Macs Fan Control | smcFanControl | TG Pro |
| --- | --- | --- | --- | --- |
| Temperature-driven curve | Multi-step with hysteresis and dwell | Two-point sensor ramp | Minimum RPM only | Yes |
| Anti-spike rate limiting | Yes, configurable | No | No | No |
| Graphical curve editor | Yes | No | No | No |
| Measures your machine to suggest a curve | `fanctl calibrate` | No | No | No |
| Controls every fan | Yes | Yes | First only | Yes |
| Menu bar UI | Yes | Yes | Yes | Yes |
| Survives an unclean exit safely | Falls back to SMC control | Leaves RPM latched | — | — |
| Cost | Free, MIT | Free / paid tiers | Free | Paid |
| Source available | Yes | No | Yes | No |

Not a like-for-like comparison — the commercial tools do far more (per-sensor
dashboards covering every SMC key, external drive SMART temperatures, battery
diagnostics, Fahrenheit, named custom presets). This one does a curve, quietly,
and gets out of the way.

## FAQ

### Why is my Mac hot but the fan is not spinning up?

Either a previous tool latched a manual RPM into the SMC ([see above](#why-this-exists)), or nothing is wrong and you are seeing Apple's stock behaviour, which permits 90–100 °C with a nearly idle fan. `fanctl status` tells you which: `smc mode forced (F0Md=1)` means something latched it. `sudo fanctl auto` clears it.

### Can I run this alongside Macs Fan Control?

No. Both write `F0Md` / `F0Tg` / `F0Mn`, last writer wins, and `fanctl` rewrites every 3 seconds (every 0.5 s while ramping) — so it becomes a permanent tug of war and neither curve behaves as designed.

One clarification, since it causes confusion: **Macs Fan Control's privileged helper sitting in the background is not a conflict.** It is an on-demand MachService that writes to the SMC only when the app calls it over XPC. With the app closed it just waits. The conflict starts the moment you open the app window.

### Is this safe?

The dangerous direction is pinning the fan *too low*, and the lowest curve step deliberately does not pin at all — it returns control to the SMC. `critical_temp` overrides everything at 98 °C on the raw peak reading. That said, this writes directly to the SMC, and if you author your own curve the responsibility is yours. Validate with `fanctl -n -v daemon` first.

### Does it work on Intel Macs?

It should. Both binaries are universal (arm64 + x86_64) and sensors and fan keys are discovered at startup. It was developed and measured on Apple Silicon, so the shipped curve values are tuned for an M4 mini — expect to adjust them. `mode = auto` picks the right control method for your machine on its own.

### Why does it need a `sudoers` rule?

Fan control requires root, and prompting for a password on every menu bar click is unusable. The rule permits exactly one script — `/usr/local/libexec/fanctl-admin` — which runs a fixed set of verbs and never passes caller input to a shell. Everything the rule allows is listed in [What it touches](#what-it-touches-on-your-system). `uninstall.sh` removes it.

### The shipped curve is wrong for my machine. Now what?

It probably is — those RPM numbers were measured on an M4 mini. Run
`sudo fanctl calibrate` and it will tell you what your machine actually costs
at each temperature, then hand you a curve to match.

### Will this drain my MacBook battery?

Running the daemon costs about 0.017 % CPU, which is negligible. Running the *fan* faster is not: a curve that keeps the fan at 2900 RPM will cost real battery. If you are on a laptop, start from the Quiet preset.

### How do I make it quieter?

Pick the Quiet preset in the menu bar, or raise the curve thresholds so each RPM step arrives later. Lowering `slew_up` makes the changes themselves less noticeable without changing the temperatures you settle at.

## Working on it

```sh
make            # the daemon and the app
make test       # the app's logic checks
make app        # just the app, when only Swift changed
```

`make test` covers the curve editor's editing rules and the config rewriter,
driven through the real event handlers rather than by calling into the model —
the rules exist to stop a drag producing a curve the daemon accepts and then
behaves oddly on, so testing below the event layer would not test them. It
creates no window and runs on a headless machine.

Not covered, and worth knowing before trusting either: `fanctl calibrate` has
no automated test beyond its interpolation, and the multi-fan path has only
ever run on a machine with one fan.

## Uninstall

```sh
sudo ./uninstall.sh           # keeps your config
sudo ./uninstall.sh --purge   # removes it too
```

Restores the fan to macOS automatic control and removes the daemon, menu bar app, `LaunchAgent`, `sudoers` rule, and root helper.

## What it touches on your system

Everything, in one table — you are being asked to install a root daemon, so this should be explicit.

| Path / target | Why |
| --- | --- |
| `/usr/local/bin/fanctl` | The binary |
| `/usr/local/etc/fanctl.conf` | Your config. Reinstalling never overwrites it |
| `/usr/local/libexec/fanctl-admin` | Root helper the menu bar app calls |
| `/etc/sudoers.d/fanctl` | Allows **that helper only**, without a password |
| `/Library/LaunchDaemons/com.local.fanctl.plist` | Starts the daemon at boot |
| `~/Library/LaunchAgents/com.local.fanctl.menubar.plist` | Only exists if "Start at login" is on |
| `/Applications/Fanctl.app` | The menu bar app |
| `/usr/local/var/log/fanctl.log` | Log. One line per step change |
| `/etc/newsyslog.d/fanctl.conf` | Rotates that log past 512 KB |
| SMC keys `F0Md` / `F0Tg` / `F0Mn` | The fan speed itself |

## License

MIT — see [LICENSE](LICENSE).
