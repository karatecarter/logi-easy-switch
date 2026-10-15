# Logi Easy Switch

Experimental macOS tooling for controlling Logitech Easy-Switch devices. The
native app talks HID++ directly to connected Bluetooth devices through macOS
IOKit; it does not depend on Logi Options+ or its private local service.

This project is unofficial and is not affiliated with Logitech. Options+
updates may change or remove the private API.

## Requirements

- macOS
- Input Monitoring permission for the native app
- Node.js 22 or newer for the prototype CLI
- The destination computer must be awake

## Native app build (without Xcode)

The menu-bar app is native AppKit/SwiftUI and follows the same build model as
CenterStage and DisplayGain: it only requires `swift` on `PATH`, not Xcode or
the Xcode Command Line Tools. Run `Scripts/make-app.sh`. The result is a
self-contained `dist/Logi Easy Switch.app`; a Mac running that app does not
need Swift or Node.

## Menu-bar app

Run the built app from `dist/Logi Easy Switch.app`. Its normal menu lists only
targets paired to both default devices, and switches that pair together.

Hold Option while the menu is open to replace that list with a submenu for each
available Logitech keyboard or mouse, allowing independent device switching.
Settings saves the default mouse/keyboard and lets you record global hotkeys
for every default-pair target and every paired device-specific target.

The first launch may require enabling Logi Easy Switch in System Settings →
Privacy & Security → Input Monitoring and then relaunching the app. Direct
HID++ access currently discovers devices connected to this Mac over Bluetooth.
The legacy Node CLI below still uses the older Options+ socket protocol.

## Commands

```sh
cd /Users/dan/repos/logi-easy-switch

# Show devices known to Options+.
node src/cli.mjs list

# Show only devices Options+ currently considers available.
node src/cli.mjs list --connected

# Show or change the default pair used by commands without --device.
node src/cli.mjs defaults
node src/cli.mjs set-defaults --mouse dev00000039 --keyboard dev00000020

# Show paired computers and each device's actual channel mapping.
node src/cli.mjs targets

# Switch the ERGO K860 and MX Master 3S together by computer name.
node src/cli.mjs switch-to HHGTPA-G09HFF --yes

# Select a different device pair just for this one switch.
node src/cli.mjs switch-to HHGTPA-G09HFF --device dev00000021 --device dev00000020 --yes

# Switch by channel. This works only when that channel maps to the same
# computer on every selected device.
node src/cli.mjs switch 1 --yes
```

`list --connected` shows the MX Vertical on this Mac, but its present
Easy-Switch records are all unpaired. It can be selected with `--device` or
saved as the default mouse only after it has been paired to the desired host(s)
on its physical Easy-Switch channels.

Switching by computer name is intentional. On the tested setup, `macmini` is
channel 2 on the ERGO K860 but channel 3 on the MX Master 3S. Sending one raw
channel number to both would split the devices.

Channel switching verifies that all selected devices have the same destination
on that channel; otherwise it tells you to use `switch-to` or target a single
device. A single device can always be addressed explicitly:

```sh
node src/cli.mjs switch 1 --device dev00000020 --yes
```

## Safety behavior

- Switching requires `--yes`.
- `switch-to` fails before changing anything unless every managed device has
  a pairing with the requested computer name.
- A device already connected to the destination is skipped.
- The mouse switches before the keyboard.
- Device IDs and HID++ feature indexes are discovered at runtime.
- `--device` can be repeated to select any Logitech input devices for one
  command. Without it, the saved defaults are used (ERGO K860 + MX Master 3S
  until you save another pair).

## Shortcut integration

After live switching is validated, the CLI can be called from a macOS Shortcut,
Raycast, BetterTouchTool, or the native menu-bar wrapper planned for this
project. Use an absolute command and working directory in automation tools.

## Protocol notes

Requests use this frame:

```text
LE32(inner length)
BE32(protocol-name length) + "json"
BE32(message length) + JSON
```

Host changes are `SET /change_host/<device-id>/host` requests carrying a typed
`logi.protocol.devices.ChangeHost` protobuf-JSON payload. Newer agents may send
a binary protobuf greeting before the JSON response; the client consumes and
ignores that greeting.
