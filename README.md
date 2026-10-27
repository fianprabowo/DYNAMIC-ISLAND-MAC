# DYNAMIC-ISLAND-MAC

A Dynamic Island for the MacBook notch, in the style of NotchNook. It's a menu bar app built with SwiftUI and AppKit.

## Features

- **Collapsed notch.** While something is live, wings appear beside the notch:
  - album art and equalizer bars while Spotify or Music plays;
  - a pulsing Claude icon while Claude Code is working;
  - a badge for unread notifications.
- **Notifications on the notch.** When another app posts a notification, the notch drops down for a few seconds with the app's icon, title and message. Click it to open the app.
- **Expanded notch.** Hover over or click the notch to open it. Pin it (next to the settings icon) to keep it open. It has three tabs:
  - **Nook:** now playing with controls, a calendar week strip with events, and Claude usage (plan limits left plus tokens today).
  - **Alerts:** every notification, from the app and from other apps. Remove them one by one or clear them all. They are kept in memory only, until removed or the app quits.
  - **System:** battery, CPU, memory, network and temperatures.
- **Floating mode.** Turn off *Pin to Notch* in the menu bar icon's menu to let the island float freely.

## Requirements

- macOS 27 (the Xcode project's deployment target).
- Xcode.
- `jq`, for the Claude Code status line script.

## Build and run

Open `DynamicIsland.xcodeproj` in Xcode and run the `MyApp` scheme. You can also build it from the command line:

```sh
xcodebuild -scheme MyApp -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/MyApp.app "/Applications/Dynamic Island.app"
open "/Applications/Dynamic Island.app"
```

On first use macOS asks for these permissions:

- **Calendars:** for the calendar strip.
- **Automation (Spotify / Music):** for the current track and playback controls.
- **Full Disk Access:** for notifications on the notch. macOS has no API for other apps' notifications, so the app reads Notification Center's database, which only apps with Full Disk Access can open. Add the app in System Settings → Privacy & Security → Full Disk Access. It shows there as MyApp.

  To see an app's notifications only on the notch, set its alert style to None in System Settings → Notifications and keep *Show in Notification Center* on. Otherwise they also appear as banners in the top-right corner. macOS writes a notification to the database about five seconds after it arrives, whatever its style, so its details reach the notch about five seconds late.
- **Accessibility:** to show a notification on the notch right away. Many apps (Slack, WhatsApp, Mail, Messages) raise their Dock badge the moment a notification arrives; the app watches the Dock's badges and shows "New notification" for that app at once, then fills in the details when they arrive. Apps without a Dock badge only get the delayed banner.

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
