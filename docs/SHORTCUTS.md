# Shortcut launcher

The shortcut launcher shares the existing menu bar app, with independent configuration and no dependency on Logitech devices or MQTT. Open **Shortcuts Settings…** in the menu bar, add buttons, and record a launcher hotkey. **Show Shortcuts** opens the same borderless floating panel. The hotkey toggles it. The launcher measures its tiles and expands vertically first, then adds columns and grows wider only if the content exceeds the usable screen height. Resizing stays centered on that screen and animates with folder entry, Back and automatic return. It respects the menu bar/Dock area; scrolling remains available only when even the widest screen-fitting layout cannot show everything. Image, favicon and file/application icons fill the space above a bottom-aligned label while retaining the ordinary tile height.

Clicking outside the launcher dismisses it without consuming the click or restoring focus away from the clicked app. This includes clicks in other Switchboard windows and in other apps.

## Configuration

- Each button has a name, a searchable visual icon picker, physical key binding (optionally modified), type, folder and dismissal rule. Record numpad 1 to distinguish it from the top-row 1. Bindings only apply to the current folder while the launcher has keyboard focus. Duplicate bindings produce a visible error rather than executing multiple actions.
- Add a Folder button, then assign other buttons to it. Nested folders are supported. The picker prevents cycles; a folder with children must be emptied before changing its type. Removing a folder removes its contents. Move up/down reorders buttons within a folder.
- Escape closes the launcher; Left Arrow or Delete goes to the parent folder. Folder navigation uses a short slide-and-fade transition, reversing direction for Back and automatic returns. Reduce Motion disables the sliding animation. Clicking a button and pressing its assigned key have the same behavior. Opening always starts at the top level. Closing restores the previously active app if the launcher still has focus.
- The launcher hotkey requires a modifier. If it conflicts with a device-switching binding, the launcher takes priority. macOS registration failures appear in Shortcuts Settings. Delete clears a recorded binding; Escape cancels recording.

Settings save automatically under the separate `shortcutDeck.v1` defaults key. Home Assistant access tokens are stored in Keychain; scripts and action parameters are stored as ordinary settings. Don't put secrets in script source or JSON if you can retrieve them from a credential store instead.

## Dismissal

Two independent checkbox rows configure **Dismiss [seconds] seconds after opening** and **Dismiss [seconds] seconds after an action by default**. Unchecking a row disables its timer while retaining the seconds value. The opening timer resets during folder navigation. Existing positive opening timeouts remain enabled after upgrading; an existing zero timeout remains disabled.

Per button, **Auto-dismiss behavior**:

| Rule | Behavior |
| --- | --- |
| Default | Inherit global action dismissal and delay; if disabled, restart the window timeout. |
| Always | Close after successful execution and the button's delay; zero closes immediately. |
| Never | Cancel both dismissal mechanisms until the next action, folder navigation, or reopening. |

Actions inside folders also offer **Return to [folder] [seconds] seconds after running action**. It defaults to Parent folder, meaning the same destination as Back, and can target any folder or Top level. Return runs after a successful action, keeps the launcher open, and takes priority over auto-dismiss and the opening timeout for that action. Zero returns immediately. Navigating, starting another action or closing cancels a pending return. A deleted destination falls back to the parent. Multi-action controls inside folders share this behavior; group containers are skipped when resolving the parent.

An action cancels the current timeout while it runs. Failures stay visible for inspection. Folders only navigate and reset the window timeout. Additional actions are disabled during execution to avoid repeated toggles. Delays are bounded to one day.

The launcher shows a countdown progress bar whenever an opening timeout, after-action dismissal, or folder-return timer is active. It drains as the timer runs and shows the remaining seconds plus **Auto-dismiss** or **Return to [folder]**. Cancelling or replacing the timer clears or resets the bar. The display uses the same monotonic deadline as the timer.

## Keychain prompts during development

The MQTT broker password and Home Assistant token are separate Keychain items. The app caches each credential in memory for the current process, shares it between settings and runtime operations, and avoids writing an unchanged credential back to Keychain. A denied read is remembered for that session so background refreshes cannot repeatedly prompt. Use **Reload password from Keychain** or **Reload token from Keychain** to explicitly retry. Loading a password into settings does not save or delete it.

A new build may still require authorization for each item. The default ad-hoc signature identifies a particular build rather than a stable developer identity. Choose **Always Allow** for each credential if appropriate for your own build; this does not guarantee approval survives the next changed ad-hoc build. For durable identity across updates, build with an appropriate installed signing certificate using `LOGI_SIGNING_IDENTITY`. The build script's `tccutil` privacy reset is separate from Keychain item access control; it does not delete the stored credentials or reset their Keychain ACLs.

## Icons

The **Icon** selector offers **Symbol**, **Custom image**, **Favicon** for Open URL actions, and **File / application icon** for Open File actions. Symbol opens the searchable symbol grid. Custom image offers **Choose image file…** and **Paste image**; copy an image, screenshot or image file to the clipboard, then click Paste image. A preview shows the selected icon.

Selecting **Favicon** starts downloading the website's icon immediately after a short debounce. It checks declared icon/touch-icon links and falls back to `/favicon.ico`, following redirects and trying supported raster icons. The normalized image is cached in the button, separately from custom images, so opening the launcher does not make another download and the icon works offline or on synced Macs. Use **Refresh favicon** to download again; changing the URL fetches a new icon. The app contacts the website and its declared icon hosts directly rather than using a third-party favicon lookup service. Only HTTP/HTTPS URLs are supported; errors appear inline and a symbol remains available as fallback. Source responses have bounded sizes and timeouts. Cached favicons count toward the MQTT configuration size limit.

Imported images are normalized into PNG thumbnails of up to 128 pixels, preserving transparency. Source files are limited to 20 MB and 64 million pixels; stored thumbnails are bounded to 12 KB, downsizing further if necessary. Image bytes are embedded in the button so the original file is not needed after import and images travel through backups and MQTT sync. Embedded images count toward the existing 60 KB configuration sync limit. Explicit image/app icons take precedence over dynamic symbol icons. Application icons are resolved from the installed app on each Mac; that app must be installed there.

## Actions

New shortcuts default to **Open File**, including shortcuts added inside folders and multi-action controls. The file chooser or URL field appears directly after Type. Single-line field labels sit beside their input.

**Switch Logitech device:** Choose Keyboard, Mouse or Both (the default), then select a destination from the remembered, visible computer list. The action uses each Mac's default keyboard/mouse from main Settings. With MQTT enabled, Both uses the existing pair-switch command; keyboard-only and mouse-only requests use `<namespace>/command/devices` with JSON `{"target":"computer display name","devices":"keyboard"}` (or `mouse`). Update all participating Macs and allow this topic in broker ACLs for scoped switching. Retained commands, unknown destinations and invalid scopes are rejected. Sending a network request does not confirm physical completion. Without MQTT, the requested devices must be connected locally; every selected device's pairing is validated before switching, and the mouse moves before the keyboard for Both. Scope-specific requests do not announce that the entire pair moved.

**Open File:** Choose this type and use **Choose file…** to select an app or document. Apps launch or activate through Launch Services; documents open in their default application. Existing Launch application shortcuts remain compatible under this new label. The icon selector's **File / application icon** uses the selected file's Finder icon.

Selecting a `.webloc`, `.inetloc`, or Windows `.url` Internet Shortcut converts the action to **Open URL** using its stored destination. If it has a Finder custom icon (including one stored in its resource fork), that icon is rasterized and imported as **Custom image** automatically. After conversion, the original Internet Shortcut file is no longer required. Malformed shortcut files produce an error instead of silently opening a guessed address. Document paths remain local for MQTT sync; followers can select their own counterpart file in **Shortcut sync → Local file**. Application bundle IDs continue to resolve installed apps across Macs.

**Open URL:** Choose this type and enter a full URL. Web URLs open in the default browser; application links such as `mailto:` use the registered handler. URLs are passed directly to Launch Services, without invoking a shell. Invalid URLs and missing handlers report errors.

**Home Assistant:** Set the base URL and save a long-lived access token under Home Assistant connection. Use **Test Connection** to validate the current URL and token with an authenticated, read-only API status request. It does not run a shortcut or save the token; click **Save token to Keychain** to make an edited token available to launcher actions. Authentication failures, redirects and unexpected server responses appear inline. This uses REST and is separate from MQTT switching. Use HTTPS on remote networks; HTTP is available for local installations but transmits the token without encryption. Redirects are rejected to avoid forwarding credentials.

Actions and entities load automatically into searchable dropdowns when you edit a Home Assistant button. Use **Refresh actions and entities** to reload them. Entity choices display friendly names and IDs, and filter by the action's target domains; **Show entities from all domains** bypasses the filter. Selecting an entity builds valid JSON and preserves extra action parameters. Simple toggles require no JSON editing. **Advanced action settings** retains access to additional parameters, multiple entities, templates and response settings.

Light actions default to an automatic state-aware bulb, including existing light buttons. On is a yellow filled bulb; off is a dim outline; unknown/unavailable states do not claim the light is off. Multiple entity targets illuminate when any is on. Choose a custom icon with the visual picker to disable automatic light icons, or enable **Automatic lightbulb icon from entity state** to restore it. A custom icon template takes precedence. Device/area-only targets need an explicit entity for automatic light readback.

For advanced configuration, an example is:

```text
action: light.toggle
data: {"entity_id":"light.office"}
text template: {{ states('light.office') }}
icon template: {{ 'lightbulb.fill' if is_state('light.office', 'on') else 'lightbulb' }}
```

The icon template must return an SF Symbol name (not an HA `mdi:` icon). Templates are optional. For response-capable/response-required actions, enable the response data toggle. Responses are accepted but not currently exposed as button text; use the template for text. These endpoints and response rules follow the [Home Assistant REST API](https://contributors.home-assistant.io/core/internals/rest-api/).

**Apple Shortcuts:** Enter the exact name of a shortcut in the Shortcuts app. Execution uses `/usr/bin/shortcuts run` with a separate name argument.

**AppleScript:** Enter source code, executed by `/usr/bin/osascript -e`. The packaged app includes the Apple Events entitlement and usage description. macOS may ask for Automation permission for target apps; UI scripting may also require Accessibility permission.

**Python:** Enter absolute interpreter and script paths. The default interpreter is `/usr/bin/python3`; use your environment's Python path if needed. Python is not bundled. No shell expansion is performed. Interpreter paths with spaces work. Scripts run with the app's user privileges; configure only scripts you trust.

**Microphone mute:** Toggles the default input device's Core Audio mute property and reads the same property for its live icon/text. It affects that device, rather than a conferencing app's private mute state.

**Volume up/down/mute:** Controls the default output device. Volume changes in 6.25% increments. Readback supplies volume percentage and speaker icon. Audio devices must expose the relevant Core Audio controls; unsupported devices show errors rather than claiming success.

**Camera:** Configure an app-specific AppleScript command to toggle the camera in the intended app. Optionally provide a read-only state AppleScript returning `on` or `off`. Without it, the button displays “App-specific” and a neutral camera icon. There is no universal implementation here for toggling cameras in arbitrary apps.

Visible button presentations refresh in cycles with a two-second pause between cycles and refresh after actions. HA requests have a 15-second request timeout. State scripts run automatically while the launcher is visible; keep them read-only and fast. Processes have a 60-second limit, are terminated on timeout, and their output is capped to 64 KiB when read back for errors. Closing prevents a completed action from dismissing a newly opened session.

## Multi-action buttons and thermostat preset

Use **Add → Multi-action button** to create one tile with several independent controls. Add actions or folder controls in that tile's editor, then click each control to configure its action, key and dismissal rule. Existing shortcuts can be assigned to a multi-action button with the **Folder / multi-action button** picker. The parent tile supports a Home Assistant text template; enable **Use dynamic text as the full button title** to replace its static name. Text preserves line breaks.

Controls are independent: clicking + only executes +, rather than executing every control. Their keys share the current folder's key scope, so conflicts with other tiles are reported. Folder controls show their child shortcuts; Back returns to the folder containing the parent tile.

For the requested thermostat layout:

1. Choose **Add → Thermostat preset**.
2. Select your climate entity in **Thermostat** and the adjustment script in **Adjustment script**. The preset defaults to `script.adjust_thermostat`.
3. The + control stores `{"increment":"ticks"}` and − stores `{"increment":"-ticks"}`. Taps accumulate separately for each control; one second after the last tap on that control, Switchboard calls the script once with the signed count as a JSON number. Three + taps send `{"increment":3}`; two − taps send `{"increment":-2}`. Each tap resets that control’s one-second timer. Other parameters are preserved, and existing numeric thermostat preset payloads migrate automatically. Both controls default to Never dismiss. Queued adjustments still run if you close or navigate away from the launcher, but their completion cannot dismiss or redirect a newer session. Quitting the app before the debounce expires does not persist the pending taps.
4. Mode opens Cool, Heat, Auto and Off controls using `climate.set_hvac_mode`. Selecting the thermostat supplies their entity target. Edit these controls if your device uses different HVAC modes; Home Assistant's [climate action](https://www.home-assistant.io/actions/climate.set_hvac_mode/) accepts the device's supported mode names.
5. Assign keys to +, −, Mode and its child shortcuts as desired. Each action retains its own dismissal settings.

Selecting a thermostat generates this live layout automatically:

```text
Thermostat - 72
Heat set to 74
```

The preset's +/− controls immediately preview one step per tap while accumulating the outgoing count. **Updating setpoint…** identifies the unconfirmed preview. Existing controls created by the thermostat preset also get this behavior. The expected value stays visible while Home Assistant still reports the old setpoint; reported current temperature and mode continue to refresh. Confirmation clears the indicator, a failed action restores the latest reported text, and after ten seconds the reported value takes precedence even if different (for example, a device limit). The script still runs unchanged. This assumes one tick adjusts the setpoint by one displayed temperature unit; arbitrary custom template layouts and range setpoints are not guessed. The requested `… set to [number]` layout, with optional unit suffixes, is supported.

The first temperature comes from `current_temperature`, the mode from the climate entity's state, and the setpoint from `temperature`. A low/high range is shown when the device supplies range targets instead of a single setpoint; missing values use an em dash. You can edit the generated template to change formatting. Choosing another thermostat regenerates it and updates the mode targets. Mode actions refuse to run until an entity has been selected.

Multi-action buttons use ordinary child buttons, so their action settings, persistence, deletion, reordering, folder navigation and provider behavior remain shared with existing shortcuts.

## MQTT configuration sync

**Edit on any Mac** supports shared editing and offline changes:

1. On a Mac with the shortcuts you want to share, choose **Shortcut sync → Edit on any Mac → Create new group from this Mac**.
2. Copy its **Shared group ID**. On other updated Macs, choose **Edit on any Mac** and paste that group ID. Use the same broker and namespace everywhere.
3. A newly joining Mac waits for the group's first retained state before enabling shared editing, backing up its previous local configuration before replacement. Once initialized, each Mac can edit offline; edits are saved immediately and sent after reconnecting.

Each Mac publishes its merged state to its own retained topic, `<namespace>/shortcuts/shared/<group-id>/<mac-sync-id>`, and subscribes to the group's `+` topic. Broker ACLs must allow each member to read all topics in its group and write its own topic. The group ID selects a shared space; broker authentication and ACLs establish trust. All members must use the updated app for this mode. The UI shows this Mac's sync ID for ACL configuration.

Button changes use causal version vectors rather than wall-clock timestamps. Changes to different buttons merge automatically, including concurrent additions. Deletions retain tombstones so an offline peer cannot resurrect a deleted button with an older snapshot. Concurrent changes to the same button (including edit versus delete) preserve both versions and show a conflict picker in Shortcut sync. A stable provisional version is displayed in the launcher until you select which to keep. Resolving a conflict propagates to the group. Timer settings form one shared conflict unit. Concurrent ordering changes combine deterministically while retaining all live buttons. Children whose folders were concurrently deleted, or whose moves create a cycle, are promoted to top level to keep them reachable.

Local-only settings and paths remain local, just as in Publish/Follow mode. Incoming changes and conflict resolutions are backed up. The existing 60 KB transport limit now includes version metadata and deletion history; oversized state reports an error instead of silently dropping updates. Turning sync Off stops sharing without deleting local shortcuts. Switching to another group can replace shared configuration, so use the export/backups controls when changing groups.

To migrate an existing Publish/Follow setup, create a new shared group on the former publishing Mac, then move each follower to Edit on any Mac with that new group ID. Legacy modes remain supported and do not receive new shared-group edits.

### Legacy one-way Publish/Follow

Shortcut sync is optional and starts Off. It uses the TLS MQTT broker, credentials and namespace configured in the app's main **Settings** window, with a separate MQTT connection from device switching. Configure the same broker and namespace on participating Macs. No Logitech hardware is needed for shortcut sync, but the main MQTT setting must be enabled.

On the Mac where you edit shortcuts:

1. Open **Shortcuts Settings → Shortcut sync**.
2. Set **Sync mode → Publish from this Mac**.
3. Copy the **Publisher ID**.

On every other Mac:

1. Configure the broker in main Settings, then open **Shortcuts Settings → Shortcut sync**.
2. Set **Sync mode → Follow another Mac** and paste the editing Mac's publisher ID.
3. Wait for **Synced revision …**. Configure that Mac's Home Assistant URL/token and Python paths as needed.

The editing Mac sends an updated retained snapshot after a short pause in edits, and republishes its current configuration after reconnecting. **Publish now** forces another snapshot. A follower subscribes to the chosen publisher's topic and accepts newer revisions, including retained snapshots sent while it was offline. It preserves the most recently applied configuration locally, so the launcher works without the broker. Turning sync Off retains current shortcuts and enables local editing. To move the editing role to a different Mac, switch the old publisher Off, set the new Mac to Publish, and update followers to the new publisher ID.

Shared: button names, hierarchy, keys, icons, action data and script source, templates, dismissal/return settings, and global timer settings. Local: launcher hotkey, Home Assistant URL, all Keychain items, broker settings and Python interpreter/script paths. Script files are not transferred. Follower Python path overrides appear in the sync section and are preserved by button UUID when new snapshots arrive. Script names and inline AppleScript are shared; ensure their target apps or Apple Shortcuts exist on each Mac. Secrets embedded in script source or action parameters would be shared with that content; use credential stores instead.

Before replacing a changed local configuration, the follower saves a JSON backup under `~/Library/Application Support/Switchboard/ShortcutBackups`, retaining ten backups. If that backup fails, the incoming configuration is not applied. **Show backups**, **Export backup…**, and **Import backup…** provide recovery and transfer; turn sync Off before restoring on a follower. JSON exports include local configuration but no Keychain items. Importing on a publisher publishes the imported shortcuts.

Snapshots use `<namespace>/shortcuts/config/<publisher-id>`. Restrict broker ACLs so only the editing Mac's account can write this topic, while followers can read it. The publisher ID selects a source; broker authentication and topic permissions establish trust. Received configuration is validated and does not execute actions on receipt. Shared script/state-template behavior still takes effect when you use the launcher, so only follow a trusted editing Mac.

Configure broker persistence if retained snapshots must survive broker restarts. This uses the app's existing QoS 0 transport: the publisher's **Sent revision** status does not confirm broker storage or follower delivery; a follower's **Synced revision** confirms application on that Mac. Use **Reconnect** or **Publish now** if needed. Snapshots are limited to 60 KB and 500 buttons; oversized or malformed snapshots report errors. In legacy Publish/Follow mode, only one designated editing Mac is supported per shared configuration; use Edit on any Mac for multi-Mac editing. Separate publisher IDs isolate their configurations.

Automated tests cover snapshot filtering/merging, invalid envelopes and folder cycles, follower revision handling, offline local persistence and backup failure protection. Actual broker ACLs, retained-message storage, reconnects and multi-Mac interaction require a live deployment smoke test.

## Action framework and future Stream Deck adapter

`DeckButton.kind` is an extensible string, and its settings are a provider-owned dictionary. UUID button IDs are stable action contexts. `DeckActionProvider` separates execution and presentation from the SwiftUI editor and launcher; `BuiltinDeckProvider` implements the first set. Unknown kinds survive configuration round trips and report an unsupported-provider error. Add providers to `DeckController.providers` and editor fields alongside them.

I inspected Elgato's [manifest reference](https://docs.elgato.com/streamdeck/sdk/references/manifest/) and [plugin WebSocket API](https://docs.elgato.com/streamdeck/sdk/references/websocket/plugin/). Plugins declare actions and executable/runtime information in a manifest and communicate with a host over a registered WebSocket connection. This suggests a compatibility host is feasible, but importing a manifest alone will not run arbitrary plugins.

A future adapter should:

1. Validate a selected `.sdPlugin` bundle's manifest, OS support, executable paths and runtime requirements. Store plugin/action UUIDs and serialized instance settings in the provider settings dictionary. Launch only explicitly installed plugins.
2. Run a loopback-only WebSocket host, launch a plugin with port/registration arguments, authenticate registration, and assign a virtual device/grid plus stable action contexts.
3. Extend the provider lifecycle with visibility, settings-change and shutdown hooks. Send appearance/disappearance and key-down/key-up events as folders and buttons change.
4. Cache incoming title/image/state updates and expose them through presentation. Extend `DeckPresentation` with bounded raster image support; currently icons are SF Symbols. Keep the launcher's name/key labels separate from plugin titles.
5. Persist per-instance/global plugin settings and host a property inspector with a restricted message bridge. Implement its settings events separately from plugin execution.
6. Isolate plugin processes, bound WebSocket messages/images, implement restart/error reporting, and test representative plugins. Node runtimes, native dependencies, Stream Deck identity assumptions, device-specific features and distribution/licensing need individual assessment.

Round one deliberately does not discover, install or execute Stream Deck plugins. The provider boundary and preserved unknown settings avoid coupling the launcher to the built-in action types, while lifecycle hooks and image support remain explicit adapter work.

## Validation

`swift test` covers configuration round trips including future provider settings and distinct physical keys, dismissal overrides, literal subprocess argument handling, process failure propagation and rejected incomplete camera/HA actions. Existing security tests also run. Live Home Assistant calls, Automation consent, camera behavior, audio hardware support, focus restoration and visual layout require an interactive smoke test on the intended Mac.
