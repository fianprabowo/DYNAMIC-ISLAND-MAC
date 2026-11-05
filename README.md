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
- **Notifications on the notch.** When another app posts a notification, the notch drops down for three seconds with the app's icon, title and message. If the app's Dock badge goes up first, the notch drops down right away with "New notification", then again with the details about five seconds later. Click it to open the app. Notifications that arrive together show one after another; three or more from one app show as one banner ("Slack · 3 new notifications"). While a Focus such as Do Not Disturb is on, the notch stays quiet and notifications only go to the Alerts tab.
- **Expanded notch.** Hover over or click the notch to open it. Pin it (next to the settings icon) to keep it open. It has six tabs:
  - **Nook:** a calendar week strip with the day's events, a meeting card, and Claude usage (plan limits left plus tokens today). The card shows the meeting going on or coming next (or the event you click in the list): when it starts or how long is left, the time, calendar or place, and a **Join** button when the event has a video call link, otherwise *Open in Calendar*.
    - **Google Meet on the notch.** *Join* opens a Meet link in Chrome. Before you join, the card sets up the microphone and camera and has *Join now*. In the call, the card shows the call live (the shared screen and the cameras, recorded from the Chrome window without its toolbar) between the calendar and Claude usage, with the meeting's name, how long it has run, the microphone and camera (red while off) and *Leave*. Its expand button shows the call bigger, in a taller panel, until you go back to the Nook; there a click on the picture shows the tab. The collapsed notch shows a green camera (a red crossed-out microphone while muted) and the call's length. The live picture needs the Screen Recording permission, the Meet tab showing in its Chrome window, and the window not minimized; the controls need Chrome's *Allow JavaScript from Apple Events* in the Chrome profile the meeting is in (see [YouTube in Chrome](#youtube-in-chrome)).
  - **Media:** what's playing in Spotify, Music or YouTube in Chrome. The player you last played stays on screen while paused; when more than one has something loaded, icons in the corner switch between them. The buttons, the progress bar (drag or click it) and a click on a lyric line all act on the player shown.
    - **Spotify and Music** show the album art, controls, a progress bar and the lyrics, which follow the song line by line when they are timed. Lyrics come from [LRCLIB](https://lrclib.net), a free lyrics database: only the track's title, artist, album and length are sent, and only while the Media tab is open.
    - **YouTube** (and YouTube Music) in Google Chrome shows the video itself, muted and kept in step with the tab, so the sound stays in Chrome. The panel grows taller for it and narrows to the video below the tab bar. YouTube's red control bar and the title show on hover and while paused; a click on the video plays or pauses. Needs Chrome's *View › Developer › Allow JavaScript from Apple Events* (see [YouTube in Chrome](#youtube-in-chrome)). Videos that don't allow embedding show their thumbnail instead.
  - **Alerts:** every notification, from the app and from other apps. Remove them one by one or clear them all. The latest 50 are kept, also across restarts, in `~/Library/Application Support/<bundle id>/notifications.json` (message text included).
  - **Poke:** friends who also run Dynamic Island. Pick a friend from the list (a green dot means they're online) and press Enter in the message field (or click *Poke*), with or without a short message: their notch drops down with "Alfian poked you", and a sound plays. *Poke Back* pokes right back; *Reply* (or a click on the banner) turns the banner into a message field right there: type and press Enter to send, or Escape to cancel. Needs a shared Supabase project (see [Poke](#poke)).
  - **Timer:** a countdown with presets (1 minute to 1 hour), pause, +1 minute and stop, and Pomodoro: 25 minutes of focus, then a 5-minute break that starts on its own. A sound plays when it ends. With *Turn On Focus*, Pomodoro turns a Focus on for the focus part (see [Focus during Pomodoro](#focus-during-pomodoro)).
  - **VPN** (right of the notch, next to the pin): the profiles in the [Pritunl](https://pritunl.com) client, each with its state (connected for how long, and the address it got) and a *Connect* or *Disconnect* button. A profile that needs a PIN asks for it the first time; it's kept in the login keychain and used from then on, also for the other profiles, since a Pritunl PIN belongs to the user (hover over a profile and click the key to forget it; a profile whose server turns the PIN down asks for its own). While a VPN is connected a green lock shows beside the notch, and the notch drops down when a VPN connects or drops, also one started in the Pritunl app. Needs the Pritunl client in `/Applications`; the notch uses its command-line tool, so Pritunl's own service does the connecting. The PIN is typed in at the tool's password prompt, never passed as a command-line argument, where other processes could read it.

- **Floating mode.** Turn off *Pin to Notch* in the menu bar icon's menu to let the island float freely.

## Requirements

- macOS 27 (the Xcode project's deployment target).
- Xcode.
- `jq`, for the Claude Code status line and hook scripts.

## Build and run

Open `DynamicIsland.xcodeproj` in Xcode and run the `DynamicIsland` scheme. You can also build it from the command line:

```sh
xcodebuild -scheme DynamicIsland -configuration Release -derivedDataPath build build
ditto "build/Build/Products/Release/Dynamic Island.app" "/Applications/Dynamic Island.app"
open "/Applications/Dynamic Island.app"
```

On first use macOS asks for these permissions:

- **Calendars:** for the calendar strip.
- **Automation (Spotify, Music, Google Chrome):** for the current track and playback controls, and for YouTube and Google Meet in Chrome.
- **Full Disk Access:** for notifications on the notch. macOS has no API for other apps' notifications, so the app reads Notification Center's database, which only apps with Full Disk Access can open. Add the app in System Settings → Privacy & Security → Full Disk Access.

  To see an app's notifications only on the notch, set its alert style to None in System Settings → Notifications and keep *Show in Notification Center* on. Otherwise they also appear as banners in the top-right corner. macOS writes a notification to the database about five seconds after it arrives, whatever its style, so its details reach the notch about five seconds late.
- **Accessibility:** to show a notification on the notch right away, and to see the brightness keys. Many apps (Slack, WhatsApp, Mail, Messages) raise their Dock badge the moment a notification arrives; the app watches the Dock's badges and shows "New notification" for that app at once, then fills in the details when they arrive. Only apps that have posted a notification before announce this way, and an app whose badge goes up twice in a row without a notification (muted chats, say) stops announcing until its next notification. Apps without a Dock badge only get the delayed banner.

The app runs with the hardened runtime (so other code can't be injected into it and borrow these permissions), declaring only Apple Events and Calendars in `DynamicIsland.entitlements`. By default the app is signed ad hoc, so macOS treats each new build as a new app and asks again. To keep the permissions across builds, sign with a stable identity: create `Signing.local.xcconfig` (not committed) next to `Signing.xcconfig` with your identity, for example an Apple Development certificate or a self-signed code signing certificate:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = DynamicIsland Local Signing
```

## YouTube in Chrome

The Media tab reads and controls YouTube in Chrome, and the Nook does the same for Google Meet, with JavaScript sent over AppleScript. Chrome only allows that after you turn on *View › Developer › Allow JavaScript from Apple Events*, in each Chrome profile you use for them. That setting isn't only for this app: any app you allow to control Chrome can then run JavaScript in any tab, including sites you're signed in to. Without it, the Media tab shows the video's title and thumbnail only. The first time, macOS also asks whether Dynamic Island may control Google Chrome.

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

## Poke

Pokes travel through a [Supabase](https://supabase.com) project that you and your friends share. The free plan is enough. One person sets it up:

1. Create a project on supabase.com.
2. In *Authentication → Sign In / Providers*, turn on **Allow anonymous sign-ins**. Each Mac signs in anonymously; there are no accounts or passwords.
3. In the *SQL Editor*, run [`supabase/poke.sql`](supabase/poke.sql). It creates the tables and the rules that keep everyone to their own data.
4. In *Project Settings → API Keys*, copy the project URL and the anon (or publishable) key.

Then everyone, on their own Mac: open the notch's **Poke** tab, paste the URL and key, click *Connect* and enter a name. Each person gets a friend code like `K7QX-M2PA`; entering a friend's code makes you friends both ways. Share the URL and key privately with friends (not in this repo): the key is meant to ship in apps, but it lets anyone who has it sign up to your project.

- What's stored: in Supabase, each person's name and friend code, who is friends with whom, and pokes (sender, recipient, message) for a week. To empty the pokes every night instead, also run [`supabase/nightly-cleanup.sql`](supabase/nightly-cleanup.sql) (23:59 Jakarta time; change the schedule for another time zone). On the Mac, the URL and key in the app's preferences and the sign-in in `~/Library/Application Support/<bundle id>/Poke/`, readable by the user only.
- Pokes arrive right away while the app runs. Pokes sent while it was off show when it comes back; those older than 10 minutes go only to the Alerts tab.
- A friend is online while their Dynamic Island runs and is connected to Poke; quitting, sleeping or losing the network takes them offline within a minute or so. Every connected app can see which user IDs are online, but only friends can put a name to one. Nothing about it is stored.
- At most 10 pokes a minute per person, and messages up to 100 characters.
- Supabase pauses free projects after about a week without use. If the Poke tab says it can't reach Supabase, restore the project in the dashboard.
- *Change Project* forgets the project and this Mac's sign-in. Setting up again makes a new friend code, so friends have to add you again.

## Focus during Pomodoro

macOS has no API to turn a Focus on, so the app runs two shortcuts you make once in the Shortcuts app:

1. A shortcut named **Dynamic Island Focus On** with the *Set Focus* action: turn Do Not Disturb (or another Focus) on.
2. A shortcut named **Dynamic Island Focus Off** with the *Set Focus* action: turn it off.

Then turn on *Turn On Focus* in the Timer tab. If a shortcut is missing, the app says which one in the Alerts tab. Quitting the app during focus turns the Focus off.

## How it reads volume, brightness and headphones

- Volume comes from Core Audio, so the menu bar slider and other apps' changes show too.
- Brightness has no public API: the app reads it through the private DisplayServices framework when a brightness key is pressed. A macOS update may break it; the rest of the app keeps working.
- Headphones are noticed when macOS switches the sound output to them, so the app needs no Bluetooth access. Battery levels come from `system_profiler`.
