# Running Deadband on macOS

Deadband started on Linux, and macOS support is new. It has been tested on an
Apple Silicon MacBook Pro (macOS 26) with a Cyclone 2, a Tarantula Pro 8K and a
Logitech G502 X: remaps, live input, profiles, lighting and the mouse pages all
work there. Other controllers haven't been tried on a Mac yet, so if you have one,
your results would be really welcome in an issue.

There's no double-click app yet. For now Deadband runs from its source code,
which takes a few commands in Terminal the first time.

## Setting it up

Open **Terminal** (⌘ + Space, type "Terminal", press Enter) and paste these
lines one at a time.

1. **Get the code.** If macOS says git needs the "command line developer
   tools", click **Install**, wait for it to finish, then run the line again.
   That install also gives you Python.

   ```
   git clone https://github.com/broroeror/gamesir-linux-tools.git $HOME/deadband
   ```

2. **Make a private Python space for Deadband.** Everything it installs stays
   inside this one folder, so nothing else on your Mac changes.

   ```
   python3 -m venv $HOME/deadband-venv
   ```

3. **Install what Deadband needs.** Qt (the interface) is a few hundred MB.

   ```
   $HOME/deadband-venv/bin/pip install --no-compile hidapi pyside6 pyusb libusb-package
   ```

   The `--no-compile` matters with the Python that comes with macOS (3.9): without
   it, installing Qt stops with a `SyntaxError` about a `.tmpl.py` file. That
   error is harmless, but it ends the install early.

## Starting it

Quit GameSir's own app first if it's open, then:

```
cd $HOME/deadband && $HOME/deadband-venv/bin/python deadband.py
```

To update later, run `git pull` in the same folder.

## Adding it to Launchpad

To open Deadband like any other app (from Launchpad, Spotlight or the Dock),
build a small launcher app for it once:

```
cd $HOME/deadband && sh packaging/macos/make_app.sh
```

That puts **Deadband.app**, with its icon, in your Applications folder. It runs
the copy of Deadband in `$HOME/deadband`, so `git pull` updates it too; only if
you move that folder do you need to run the command again. Since there's no
Terminal window, anything Deadband prints goes to
`~/Library/Logs/Deadband.log` (open it with the Console app), which is worth
attaching to a bug report.

While it's running, the menu bar and the Dock's hover label may still say
"Python": the app is Python running Deadband, and macOS names it after that.

## Different from Linux

- **The Cyclone 2 needs the USB packages from step 3.** On a Mac, its dongle
  shows its settings connection without a driver attached, so Deadband talks to
  it over USB directly. If they're missing, Deadband says so and shows the
  command.
- **Switching controllers by pressing a button on them is Linux-only.** Use the
  controller picker in the header instead.
- **"Sticks → cursor" is a KDE feature,** so it doesn't appear on a Mac.
- **The G7 Pro, Kaleid and G7 SE can't be configured on a Mac yet.** They're
  detected, but their settings are reached a different way that hasn't been
  brought over.
- **Diagnostics** (`deadband --doctor`, or Settings → Diagnostics) give a
  shorter, Mac-specific report. If something doesn't show up, close Deadband
  and run this; it asks each device a few read-only questions:

  ```
  cd $HOME/deadband && $HOME/deadband-venv/bin/python deadband.py --doctor --probe
  ```

  Pasting its output into an issue is the most useful thing you can send.

## Keyboard tip

On a German (or other non-US) Mac keyboard, `~` is **Option + N** followed by
Space. Every command here uses `$HOME` instead, so you won't need it.
