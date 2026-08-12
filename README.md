# pinlock

Menu bar kiosk lock for macOS. While locked the screen stays awake and visible, but every click and keystroke is swallowed until the PIN is entered.

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
- Emergency exit: press **⌘Q** four times within 2 seconds.

Try it safely first — this locks immediately and unlocks after 10 seconds:

```sh
./pinlock.app/Contents/MacOS/pinlock 10
```

Run the self-test with `./pinlock.app/Contents/MacOS/pinlock --selftest`.
