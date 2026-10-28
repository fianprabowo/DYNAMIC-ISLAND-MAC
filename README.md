# DYNAMIC-ISLAND-MAC

A Dynamic Island for the MacBook notch, in the style of NotchNook. It's a menu bar app built with SwiftUI and AppKit.

## Features

- **Collapsed notch.** While something is live, wings appear beside the notch:
  - album art and equalizer bars while Spotify or Music plays;
  - a pulsing Claude icon while Claude Code is working;
  - minutes until your next meeting, from 10 minutes before it starts;
  - the time left on a timer;
  - a badge for unread notifications.
- **Live activities.** The notch drops down, like it does for notifications, when:
  - **Claude Code needs you** (a permission prompt, or waiting for your input) or has **finished its turn**. Click it to open the terminal Claude Code runs in. Nothing shows while that terminal is the frontmost app. Needs the Claude Code hook (see [Claude Code alerts](#claude-code-alerts)).
  - **A meeting starts in 5 minutes, and as it starts.** If the event has a video call link (Zoom, Google Meet, Teams, Webex, FaceTime and others, found in the event's URL, location or notes), the banner has a **Join** button; otherwise clicking it opens Calendar. Declined and all-day events are skipped.
  - **A charger is plugged in:** the battery level and the time until full.
  - **Bluetooth headphones (like AirPods) connect or disconnect**, with their battery levels when macOS reports them.
  - **A timer ends.**

  Only Claude Code's prompts are also kept in the Alerts tab. During a Focus, meeting reminders and Claude Code's prompts wait in the Alerts tab instead of dropping down; charging, headphones and timers show anyway.
- **Volume and brightness on the notch.** While the volume or the built-in display's brightness changes, wider wings beside the notch show the level (not over a notification banner). macOS's own indicator still shows too. Turn it off with *Show Volume & Brightness* in the settings menu.
- **Notifications on the notch.** When another app posts a notification, the notch drops down for a few seconds with the app's icon, title and message. Click it to open the app. Notifications that arrive together show one after another; three or more from one app show as one banner ("Slack · 3 new notifications"). While a Focus such as Do Not Disturb is on, the notch stays quiet and notifications only go to the Alerts tab.
- **Expanded notch.** Hover over or click the notch to open it. Pin it (next to the settings icon) to keep it open. It has four tabs:
  - **Nook:** now playing with controls, a calendar week strip with events, and Claude usage (plan limits left plus tokens today).
  - **Alerts:** every notification, from the app and from other apps. Remove them one by one or clear them all. The latest 50 are kept, also across restarts, in `~/Library/Application Support/<bundle id>/notifications.json` (message text included).
  - **Timer:** a countdown with presets (1 minute to 1 hour), pause, +1 minute and stop, and Pomodoro: 25 minutes of focus, then a 5-minute break that starts on its own. A sound plays when it ends. With *Turn On Focus*, Pomodoro turns a Focus on for the focus part (see [Focus during Pomodoro](#focus-during-pomodoro)).
  - **System:** battery, CPU, memory, network and temperatures.

  The Nook's calendar has a **Join** button on events with a video call link.
- **Floating mode.** Turn off *Pin to Notch* in the menu bar icon's menu to let the island float freely.

## Requirements

- macOS 27 (the Xcode project's deployment target).
- Xcode.
- `jq`, for the Claude Code status line and hook scripts.

## Build and run

Open `DynamicIsland.xcodeproj` in Xcode and run the `MyApp` scheme. You can also build it from the command line:

```sh
xcodebuild -scheme MyApp -configuration Release -derivedDataPath build build
ditto "build/Build/Products/Release/Dynamic Island.app" "/Applications/Dynamic Island.app"
open "/Applications/Dynamic Island.app"
```

On first use macOS asks for these permissions:

- **Calendars:** for the calendar strip.
- **Automation (Spotify / Music):** for the current track and playback controls.
- **Full Disk Access:** for notifications on the notch. macOS has no API for other apps' notifications, so the app reads Notification Center's database, which only apps with Full Disk Access can open. Add the app in System Settings → Privacy & Security → Full Disk Access.

  To see an app's notifications only on the notch, set its alert style to None in System Settings → Notifications and keep *Show in Notification Center* on. Otherwise they also appear as banners in the top-right corner. macOS writes a notification to the database about five seconds after it arrives, whatever its style, so its details reach the notch about five seconds late.
- **Accessibility:** to show a notification on the notch right away, and to see the brightness keys. Many apps (Slack, WhatsApp, Mail, Messages) raise their Dock badge the moment a notification arrives; the app watches the Dock's badges and shows "New notification" for that app at once, then fills in the details when they arrive. Only apps that have posted a notification before announce this way, and an app whose badge goes up twice in a row without a notification (muted chats, say) stops announcing until its next notification. Apps without a Dock badge only get the delayed banner.

By default the app is signed ad hoc, so macOS treats each new build as a new app and asks again. To keep the permissions across builds, sign with a stable identity: create `Signing.local.xcconfig` (not committed) next to `Signing.xcconfig` with your identity, for example an Apple Development certificate or a self-signed code signing certificate:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = DynamicIsland Local Signing
```

## Claude plan usage

The 5-hour and weekly limits come from the Claude Code status line. To set it up:

1. Copy the script:

   ```sh
   cp scripts/claude-statusline.sh ~/.claude/dynamic-island-statusline.sh
   chmod 700 ~/.claude/dynamic-island-statusline.sh
   ```

2. Add this to `~/.claude/settings.json`:

   ```json
   "statusLine": { "type": "command", "command": "~/.claude/dynamic-island-statusline.sh" }
   ```

On each refresh the script saves the status JSON to `~/Library/Application Support/DynamicIsland/claude-status.json`, where the app reads it. It also prints the model and usage bars as the Claude Code status line. Token counts for today are read from Claude Code's local transcripts in `~/.claude/projects`.

## Claude Code alerts

A Claude Code hook tells the app when Claude needs you or has finished. To set it up:

1. Copy the script:

   ```sh
   cp scripts/claude-hook.sh ~/.claude/dynamic-island-hook.sh
   chmod 700 ~/.claude/dynamic-island-hook.sh
   ```

2. Add the `Notification` and `Stop` hooks to `~/.claude/settings.json`, next to any hooks you already have:

   ```json
   "hooks": {
     "Notification": [{ "hooks": [{ "type": "command", "command": "~/.claude/dynamic-island-hook.sh" }] }],
     "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/dynamic-island-hook.sh" }] }]
   }
   ```

The script appends each event to `~/Library/Application Support/DynamicIsland/claude-events.jsonl`, where the app reads it: the event, Claude's short message (like "Claude needs your permission to use Bash"), the project folder and the terminal app, never the conversation. It starts the file over once it passes 64 KB, never prints anything and always succeeds, so it can't get in Claude Code's way.

## Focus during Pomodoro

macOS has no API to turn a Focus on, so the app runs two shortcuts you make once in the Shortcuts app:

1. A shortcut named **Dynamic Island Focus On** with the *Set Focus* action: turn Do Not Disturb (or another Focus) on.
2. A shortcut named **Dynamic Island Focus Off** with the *Set Focus* action: turn it off.

Then turn on *Turn On Focus* in the Timer tab. If a shortcut is missing, the app says which one in the Alerts tab. Quitting the app during focus turns the Focus off.

## How it reads volume, brightness and headphones

- Volume comes from Core Audio, so the menu bar slider and other apps' changes show too.
- Brightness has no public API: the app reads it through the private DisplayServices framework when a brightness key is pressed. A macOS update may break it; the rest of the app keeps working.
- Headphones are noticed when macOS switches the sound output to them, so the app needs no Bluetooth access. Battery levels come from `system_profiler`.
