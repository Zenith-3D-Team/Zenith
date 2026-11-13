# Zenith performance test

A test that measures how smoothly Zenith runs on your PC, so its numbers can be compared with
other PCs and with the next versions of Zenith. It is part of Zenith itself: you need nothing but
Zenith and Factorio 2.1 (from Steam or Factorio's own installer). Nothing to install, no scripts,
no admin rights.

## The three steps

1. **Open Zenith** and, in the main menu, click **Performance test**.
2. **Pick a mode**: Quick, Default or Extensive (below). Default is the green one.
3. **Send the results file.** When it's done Zenith shows the results; click **Open folder** to
   see the file, `Zenith-perf-<version>-<mode>.txt` (for example `Zenith-perf-0.2.0-default.txt`),
   and send it.

## How long it takes

| Mode | What it runs | Time |
|---|---|---|
| Quick | standing still and running laps, in the Factorio look (2 tests) | about 3 minutes (measured on the project's PC) |
| Default | the same in the Factorio look and the Cinematic look (4 tests) | about 6 minutes (an estimate) |
| Extensive | Default twice, plus the Low and Ultra graphics presets (12 tests) | about 17 minutes (an estimate) |

Each test takes about a minute (standing) or two (laps), plus a quarter of a minute at the start
to make the map. Default's and Extensive's times are worked out from Quick's tests, not timed yet.
Your PC may take a few minutes more or less: much of the time is Factorio and Zenith starting and
loading, which depends on the disk and the processor.

## What you'll see

- Zenith's menu shows what it's doing: making a test map, starting Factorio in the background (no
  Factorio window appears), building a small test factory, then "Test 1 of 4", "Test 2 of 4"...
- For each test a second Zenith window opens **full screen** and plays by itself: the character
  stands still looking at the factory, or runs laps round it very fast. After a minute or two it
  closes by itself and the next test starts. There is no sound.
- Please leave the mouse and keyboard alone while it's on the screen, and don't run games, videos
  or downloads at the same time: they would change the numbers. Close other games (and Factorio)
  before you start.
- At the end the results show in Zenith's menu: a line per test, **Details** for each test's full
  report (the same window as the debug menu's benchmarks, compared with your last run of that
  mode), **Open folder**, and **Copy** to put the whole file on the clipboard.

If Factorio isn't found, Zenith says so: set Factorio's folder in **Settings > Factorio** (in Steam:
right-click Factorio > Manage > Browse local files, then copy the address bar) and start the test
again.

## Stopping it

Press **Esc**, or click **Cancel** in Zenith's progress window (while the test's full-screen Zenith
covers the screen, Alt+Tab back to the first one). Closing Zenith stops it too. Factorio and the
test's Zenith stop with it; nothing is left running, and no results file is written.

Nothing of yours is changed: the test makes its own map and keeps its own settings, logs and
Factorio data in a `perf-tests\work` folder in Zenith's user folder
(`%APPDATA%\Godot\app_userdata\Zenith\perf-tests` on Windows); delete it whenever you like, the
next run makes it again. Your Zenith settings,
your Zenith worlds, your add-ons, your Factorio saves and your Factorio mods are never read or
written.

For automation, `Zenith.exe -- --perf-test=quick` (or `default`, `extensive`) runs it at once and
quits when it's done; `-- --perf-test` alone opens the choice.

## What's in the results file

The file is plain text: open it in Notepad to see exactly what you send. It holds:

- Zenith's version, the mode, when it ran and how long it took;
- your PC: the processor, how much memory, the graphics card and its driver version, what Zenith
  drew with (Vulkan, Direct3D 12...), the main screen's resolution and refresh rate, the system's
  version, Factorio's version and whether Space Age is on. Zenith reads these through its game
  engine's own calls, the same it uses to draw;
- how the test was run (full screen at your screen's resolution, vsync off, the scene and routes);
- a table with one row per test, the look and graphics preset in its name: frame times (the middle
  frame, the slowest 1%, the worst), frames per second, how many frames were slower than 16.7 ms
  and 33 ms (the ones you'd feel as stutter), the graphics card's time, draw calls, the game's speed
  (UPS, 60 is full speed) and what Zenith's mod costs Factorio each tick;
- the same numbers as one line per test (CSV) for the project's tools.

Nothing else: no names, no user name, no folder paths, nothing from your saves or files.

## If something goes wrong

Zenith says what stopped it. Send that message (a screenshot is fine), and if you can, the
`perf-tests\work\runs` folder (Zenith's log of each test) and
`perf-tests\work\factorio\factorio-current.log`.
