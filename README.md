# pinlock

Menu bar kiosk lock for macOS. While locked the screen stays awake and visible, but every click and keystroke is swallowed until the PIN is entered.

<p>
  <img src="docs/menu.png" alt="pinlock menu bar menu" width="231">
  &nbsp;
  <img src="docs/lock-when-away.png" alt="Lock When Away window: the Mac in the middle, nearby Apple devices placed by signal strength, the dashed ring marks the lock distance" width="355">
</p>

## What it is, and what it isn't

pinlock is **not** a replacement for the macOS lock screen and does not give full protection. Your session stays logged in and every app keeps running. pinlock only puts a window on top that swallows input. Anyone who can force a restart, reach the Mac over the network, or plug in hardware gets around it.

It exists so you don't have to fully lock the Mac every time you step away for a moment, while still making sure nobody can use it during the minutes you're not there. Your session, open apps and whatever is on screen stay exactly as you left them. When you leave the Mac for longer, or somewhere you don't trust, lock it properly with **⌃⌘Q**.

## Build

```sh
make            # builds pinlock.app
make install    # copies it to /Applications and launches it
make uninstall
```

## Usage

- Set a PIN on first launch (at least 4 digits). Change it from the menu bar item.
- Lock with **⌃⌥⌘L** or **Lock Now** in the menu.
- Blur, cover strength and cover colour are configurable from the menu.
- Forgot the PIN? Click **Use Mac Password** on the lock screen and enter your macOS account password.
- **Lock When Away…** opens a radar: your Mac in the middle and nearby Apple devices placed by Bluetooth signal strength. Click your iPhone (or Apple Watch) to watch it. The dashed ring is the chosen distance, and pinlock locks once the device stays outside it for 15 seconds. It locks once per absence; unlocking still needs the PIN or password.

## If you're locked out

pinlock is just a process, so nothing it does survives that process ending. In order of preference:

1. **Wait about 10 seconds.** If pinlock freezes while locked, a watchdog quits it, which removes the lock. A crash removes it too.
2. **Use Mac Password** on the lock screen if you forgot the PIN.
3. **SSH in from another machine** (needs Remote Login enabled) and run `pkill pinlock`. The lock disappears and nothing is lost.
4. **Hold the power button** (Touch ID button on Apple Silicon) for about 10 seconds to force the Mac off, then turn it on again. This always works, but unsaved work is lost. Keyboard restart shortcuts may be blocked while locked.

After a restart, pinlock never locks on its own. Even with Open at Login it starts unlocked, and Lock When Away only arms after it has seen your phone nearby. The macOS login screen asks for your Mac password, not the PIN.

Try it safely first — this locks immediately and unlocks after 10 seconds:

```sh
./pinlock.app/Contents/MacOS/pinlock 10
```

Check the watchdog — this locks, freezes, and should disappear after about 12 seconds:

```sh
./pinlock.app/Contents/MacOS/pinlock --hangtest
```

Run the self-test with `./pinlock.app/Contents/MacOS/pinlock --selftest`.
