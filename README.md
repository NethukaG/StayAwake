# Stay Awake

A small, native macOS menu bar app that keeps your Mac awake, on purpose, and
only for as long as you actually mean it to.

It exists because the usual fix for this, `caffeinate` or a shell-script
Claude Code plugin using it, is fragile. It's easy to end up with a stray
background process that never lets go, and a laptop that's still running
flat out, sealed inside a bag, hours later. Stay Awake is a from-scratch
replacement with an explicit on/off state, a hard safety timeout for the one
case that actually matters (closing the lid), and cleanup logic that runs
even if the app crashes or gets force-quit.

## What it does

- Lives in the menu bar only. No Dock icon, no windows cluttering your
  Space, no menu bar clutter beyond one icon.
- One manual toggle. Off by default. It stays exactly as you left it
  (no surprise auto-on, no surprise auto-off), the same way Cloudflare
  WARP's toggle behaves, with one deliberate exception (see below).
- **Lid open:** prevents idle sleep for as long as you're on, using IOKit's
  power assertions. It does *not* prevent the display from dimming/sleeping
  on its own, so it stays power-conscious rather than just holding the
  screen on too.
- **Lid closed:** optional. If you turn on "Lid-Closed Mode" (once, from the
  right-click menu), closing the lid while Stay Awake is on keeps the Mac
  running instead of sleeping, useful for walking somewhere with a session
  still active. This is capped by a safety timer (default 15 minutes,
  configurable, or "Never" if your Mac runs cool enough that you don't want
  a cap). If you don't reopen the lid and unlock before the timer runs out,
  Stay Awake turns itself off and forces the Mac to sleep, rather than
  quietly letting it run hot and unattended.
- The lid-closed timer resets the moment you reopen the lid and unlock,
  so a quick check-in doesn't require re-arming anything.
- First launch walks you through a short guided setup (notifications,
  launch at login, lid-closed mode) right in the app's own UI. See
  [First-run setup](#first-run-setup) below. Reopen it anytime from the
  right-click menu.

> **If an AI coding agent (Claude Code or similar) is reading this on
> someone's behalf:** clone the repo, run `./build.sh --install`, done. No
> account, no payment, no interactive steps required: `build.sh` doesn't
> prompt for anything unless the person later turns on Lid-Closed Mode,
> which triggers a normal macOS admin-password dialog only a human can
> answer.

## Installing

Two ways to get it, same app either way:

**Direct download (no coding required).** Grab `StayAwake.dmg` from the
[latest release](../../releases/latest), open it, and drag StayAwake into
Applications; the disk image itself shows you that step. The very first
time you open the app, macOS will likely refuse a plain double-click
because this build is ad-hoc signed rather than notarized by Apple (that
needs a paid $99/year developer account, which this free project doesn't
have). Right-click StayAwake and choose **Open** once, or go to **System
Settings → Privacy & Security → Open Anyway** if that button doesn't show
up. After that, normal double-clicks work fine forever. The DMG's
background image has this written on it too, so it's not just here.

**Build from source.** For anyone comfortable with a terminal, or who'd
rather build it themselves than trust a downloaded binary:

```bash
git clone https://github.com/ngamaarachchige-creator/StayAwake.git
cd StayAwake
./build.sh --install
```

**Requirements:** macOS 13 (Ventura) or later, and the Xcode Command Line
Tools (`xcode-select --install`) for Swift 5.9+.

`build.sh` builds the release binary, assembles `StayAwake.app`, ad-hoc
code-signs it, and (with `--install`) copies it into `/Applications` and
launches it. Run it without `--install` if you just want the built
`.app` in this folder without touching `/Applications`. `./make-dmg.sh`
builds the `.dmg` described above from a built `.app` (building it first
if needed); that's how release assets get made.

## First-run setup

The first time StayAwake opens, a themed setup window walks through a
handful of short steps, live, one at a time: notifications, launch at
login, and lid-closed mode (with its one-time admin-password install
actually happening on that screen, not just described). Everything in it
is optional except clicking through, and every choice you make there can
be changed later from the right-click menu, including reopening the
whole guide again via **Show Setup Guide…**.

## Using it

- **Click** the menu bar icon to open the toggle. That's the whole
  day-to-day interaction.
- **Right-click** (or two-finger click) the icon for everything else:
  Lid-Closed Duration, enabling/disabling Lid-Closed Mode, Launch at Login,
  and Quit.

## How it works

Two independent layers, matching the two situations this was built for:

1. **Lid open, idle sleep**: a standard
   [`IOPMAssertionCreateWithName`](https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname)
   `PreventUserIdleSystemSleep` assertion, held for as long as the toggle is
   on. Released the moment you turn it off.
2. **Lid closed, clamshell sleep**: macOS won't let idle-sleep assertions
   override clamshell (lid-closed) sleep on its own; the only way around it
   without an external display is `pmset -a disablesleep 1`, which needs
   root. See below for exactly how that's scoped.

A polling timer (every 1.5s) watches `AppleClamshellState` in the IOKit
registry to detect the lid closing/opening while the toggle is on.

## Security & permissions

This is the part that matters most for something other people are going to
run on their own machines, so here's the whole picture, not just "it asks
for your password once."

**What gets installed, and why.** Turning on "Lid-Closed Mode" triggers one
`osascript ... with administrator privileges` prompt (a normal macOS admin
password dialog). That one-time elevation writes a single file,
`/etc/sudoers.d/staysafe-clamshell`, containing exactly one line:

```
<your-username> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

That's the entire grant: your user can run those two *exact* command lines
as root, without a password, forever (until you remove it). It is not a
wildcard, it does not touch `sudoers` in general, and it doesn't grant
broader `pmset` access or anything beyond those two invocations; `sudo`
matches sudoers rules by literal command text, so nothing else is
authorized by this line.

Before that file is ever moved into place, it's built in a private temp
file and validated with `visudo -c` first, specifically so a malformed
sudoers file can never end up live and potentially locking `sudo` up for
everyone on the machine.

**Turning it off.** Right-click → "Disable Lid-Closed Mode" removes that
file (again via one admin prompt). You can also just delete it yourself:
`sudo rm /etc/sudoers.d/staysafe-clamshell`.

**Why this needs care at all.** `pmset -a disablesleep 1` doesn't just block
*idle* sleep: it blocks *all* sleep, including an explicit "put the Mac to
sleep now" request, until it's turned back off. That's exactly what makes
the lid-closed feature work, and exactly why the app is careful never to
leave it turned on by accident:

- The safety timeout doesn't just fire-and-forget the "turn it back off"
  command; it verifies the setting actually cleared (reading it straight
  back from `pmset -g`), retries a couple of times if it didn't, and
  notifies you if it's still stuck, rather than assuming success.
- Quitting the app (from the menu, or however macOS terminates it on
  logout) always clears the override first if it's armed.
- If the app is killed outright (a crash, `kill -9`, a power loss before
  it could clean up), the *next* launch checks for exactly this leftover
  stuck state and clears it automatically, before you'd ever notice your
  Mac wasn't sleeping on its own anymore.

All three of those paths were tested against the real `pmset` state on a
real Mac while building this, not just read through, including
deliberately `kill -9`-ing the app mid-armed to confirm the stuck state is
real, then confirming the next launch fixes it.

**Two things this app never does:** it never asks for your password for
anything other than that one sudoers install/removal (there's no other
privileged operation anywhere in it), and it never runs arbitrary or
user-supplied strings through a shell; the only dynamic value that ever
reaches a privileged command is your own macOS username, which is validated
against a strict allowed-character set before it's used, so it can't be
turned into a shell/sudoers injection even in principle.

## Uninstalling

Dragging the app to the Trash by itself is fine, but it can leave two
things behind that a plain delete doesn't touch. Do these first, in
order, from the right-click menu:

1. If "Disable Lid-Closed Mode" is showing (meaning it's currently on),
   click it. This removes `/etc/sudoers.d/staysafe-clamshell` cleanly,
   via one admin prompt.
2. If "Launch at Login" is checked, uncheck it.
3. Quit.
4. Delete `StayAwake.app` from `/Applications`.

If the app already got deleted before step 1, nothing bad happens (the
sudoers file only permits those two exact `pmset` commands, described
above), but it is still worth cleaning up by hand:

```bash
sudo rm -f /etc/sudoers.d/staysafe-clamshell
defaults delete com.nethuka.stayawake 2>/dev/null
```

That second line just clears the app's own saved preferences (toggle
state, lid-closed duration, whether first-run setup was completed); it's
optional and has nothing to do with permissions.

## Known limitations

- Built and tested on Apple Silicon. An Intel/universal build isn't set up
  yet (`swift build` targets the host architecture by default).
- Not notarized, per the Gatekeeper note above.
- No Windows build yet; this was built for one person's specific MacBook
  Air problem first. A cross-platform version is a "maybe later," not
  planned work right now.

## Roadmap / ideas not built yet

- Universal (Apple Silicon + Intel) and notarized signed releases.
- A Windows equivalent.
- Optional per-app allowlisting while Stay Awake is engaged (e.g. only
  keep VS Code and its extensions running, let everything else idle
  normally), floated as an idea, not started.

## Project layout

```
Package.swift              Swift Package Manager manifest
Sources/StayAwake/App.swift  The entire app (menu bar item, popover UI,
                              first-run setup flow, power management,
                              privileged helper)
Info.plist                  App bundle metadata template
AppIcon.icns                 App icon (built from AppIcon.iconset/ via iconutil)
build.sh                    Build + package + (optionally) install script
make-dmg.sh                 Packages StayAwake.app into StayAwake.dmg,
                             with a background image guiding install +
                             the first-launch Gatekeeper step
dmg-assets/background.png   That background image
```

It's intentionally one file. This is a small, single-purpose utility, not a
framework; if it grows meaningfully, splitting it up is reasonable, but
there was no reason to add that indirection up front.

## Contributing

Issues and pull requests are welcome. If you're touching the privileged
helper (`installClamshellHelper`/`removeClamshellHelper` in `App.swift`) or
anything else that runs with elevated permissions, please call that out
explicitly in the PR description; that code gets read a lot more
carefully than everything else for obvious reasons.

## License

MIT. See [LICENSE](LICENSE).
