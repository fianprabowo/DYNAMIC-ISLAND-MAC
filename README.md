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
  - **The Claude plan's week is about to reset** with some of the weekly limit left: on the day it resets, every hour from 9:00 until the reset (from 9:00 the day before when it resets earlier than that), how much is left and when it resets, so you can use it up first. Nothing shows once less than 1% is left. Clicking it opens the Nook. Needs the plan limits (see [Claude plan usage](#claude-plan-usage)).

  Only Claude Code's prompts are also kept in the Alerts tab. During a Focus, meeting reminders, the weekly limit's reminder and Claude Code's prompts wait in the Alerts tab instead of dropping down; charging, headphones and timers show anyway.
- **Animations**, each turned on or off under *Animations* in the settings menu: a little face beside the notch while nothing is running or only notifications are waiting (their number stays on the right, also with the VPN on). It breathes, blinks (sometimes twice, or a wink), glances around, and every so often yawns, looks around, hums or hops; it grins as the pointer comes near, glances at the badge when a notification comes in, looks surprised after a friend's poke, gets drowsy after a minute without input and falls asleep after two, and looks a little tired late at night. Its mouth only shows with an expression; a friend's poke shakes the notch and swings its hand in, with a little weather over the banner by the time of day (sunbeams in the morning, snow during the day, twinkling stars at night). The notch opens and closes smoothly, without bounce: the content drops in from the notch as it opens. *Season* dresses the notch up by the date, each until a few days after its day: at **Christmas** (1 November–28 December) snow drifts down behind every tab, piles along the bottom, and the face becomes a snowman (he follows the pointer with his eyes and carrot, waves when it comes near, his hat jumps at a poke and slips when he dozes off); at **New Year** (29 December–4 January) a fireworks show goes off behind the tabs (round bursts, rings, drooping willows, two-colored and crackling ones, several at a time, and every nine seconds a big one over the middle that lights up the panel) and the face wears a party hat that pops confetti when the pointer comes near or a friend pokes; at **Lebaran** (a week before Eid al-Fitr to four days after, by the Umm al-Qura calendar) gold stars twinkle around a crescent moon over a string of ketupat, and the face wears a peci with a little ketupat swinging beside it. *Season* can also be turned off, or set to one of them all the time.
- **Volume and brightness on the notch.** While the volume or the built-in display's brightness changes, wider wings beside the notch show the level (not over a notification banner). macOS's own indicator still shows too. Turn it off with *Show Volume & Brightness* in the settings menu.
- **Notifications on the notch.** When another app posts a notification, the notch drops down for three seconds with the app's icon, title and message. If the app's Dock badge goes up first, the notch drops down right away with "New notification", then again with the details about five seconds later. Click it to open the app. Notifications that arrive together show one after another; three or more from one app show as one banner ("Slack · 3 new notifications"). While a Focus such as Do Not Disturb is on, the notch stays quiet and notifications only go to the Alerts tab.
- **Expanded notch.** Hover over or click the notch to open it. Pin it (next to the settings icon) to keep it open. The arrows beside the pin make it wider and taller (900×280 instead of 640×180, never as wide as the screen) and back; it stays that way until you click them again. It has seven tabs:
  - **Nook:** a calendar week strip with the day's events, a meeting card, and Claude usage (plan limits left plus tokens today). The card shows the meeting going on or coming next (or the event you click in the list): when it starts or how long is left, the time, calendar or place, and a **Join** button when the event has a video call link, otherwise *Open in Calendar*.
    - **Google Meet on the notch.** *Join* opens a Meet link in Chrome. Before you join, the card sets up the microphone and camera and has *Join now*. In the call, the card shows the call live (the shared screen and the cameras, recorded from the Chrome window without its toolbar) between the calendar and Claude usage, with the meeting's name, how long it has run, the microphone and camera (red while off) and *Leave*. Its expand button shows the call bigger, in a taller panel, until you go back to the Nook; there a click on the picture shows the tab. The collapsed notch shows a green camera (a red crossed-out microphone while muted) and the call's length. The live picture needs the Screen Recording permission, the Meet tab showing in its Chrome window, and the window not minimized; the controls need Chrome's *Allow JavaScript from Apple Events* in the Chrome profile the meeting is in (see [YouTube in Chrome](#youtube-in-chrome)).
  - **Media:** what's playing in Spotify, Music or YouTube in Chrome. The player you last played stays on screen while paused; when more than one has something loaded, icons in the corner switch between them. The buttons, the progress bar (drag or click it) and a click on a lyric line all act on the player shown.
    - **Spotify and Music** show the album art, controls, a progress bar and the lyrics, which follow the song line by line when they are timed. Lyrics come from [LRCLIB](https://lrclib.net), a free lyrics database: only the track's title, artist, album and length are sent, and only while the Media tab is open.
    - **YouTube** (and YouTube Music) in Google Chrome shows the video itself, muted and kept in step with the tab, so the sound stays in Chrome. The panel grows taller for it and narrows to the video below the tab bar. YouTube's red control bar and the title show on hover and while paused; a click on the video plays or pauses. Needs Chrome's *View › Developer › Allow JavaScript from Apple Events* (see [YouTube in Chrome](#youtube-in-chrome)). Videos that don't allow embedding show their thumbnail instead.
  - **Alerts:** every notification, from the app and from other apps. Remove them one by one or clear them all. The latest 50 are kept, also across restarts, in `~/Library/Application Support/<bundle id>/notifications.json` (message text included).
  - **Poke:** friends who also run Dynamic Island. Pick a friend from the list (a green dot means they're online, an orange calendar that they're in a meeting, and under their name 🎵 the song they're listening to in Spotify or Music, which a click plays here: the same track in Spotify, otherwise a search in Spotify or Apple Music; turn off sharing yours in ⚙ → *Share What I'm Playing*) and press Enter in the message field (or click *Poke*), with or without a short message (the smiley in the field opens an emoji popup: a click adds one): their notch drops down with "Alfian poked you", and a ping sounds (pick another sound in ⚙ → *Poke Sound*: resting on one plays it, and *Choose Sound File…* adds one of your own, copied to `~/Library/Sounds` on your Mac only). **⌃⌥P** from any app pokes the friend you picked last in the Poke tab right away, without a message and without opening the notch; the notch then confirms it with "Poked" and their name. The friend you pick is remembered across launches. It needs no permission; if another app already uses ⌃⌥P, the shortcut does nothing. *Poke Back* pokes right back; *Reply* turns the banner into a message field right there: type and press Enter to send, or Escape to cancel. A click elsewhere on the banner opens the Poke tab on the chat with that friend. Above the message field, the last 20 pokes with the picked friend like in a messenger: yours on the right, theirs on the left, the newest at the bottom; the trash can beside the friend's name empties that chat on your Mac only (your friend still sees it, and new pokes show up as usual); your pokes get ticks like in WhatsApp: ✓ sent, ✓✓ grey once it reached your friend's Mac, ✓✓ green once they opened the chat (needs the latest [`supabase/poke.sql`](supabase/poke.sql)). The photo icon in the message field attaches a picture (or drag one onto the chat): it's made smaller, at most 3072 pixels and under 5 MB, without its metadata like a photo's location, and sent with or without a message; in the chat a click opens it in Preview. Pictures are kept in a private Supabase Storage bucket only the two of you can read, each person sends at most 50 a day, your app deletes yours after a day, and all of them together stay under 50 MB: when a new one would pass 48 MB, they're all deleted first (needs the latest [`supabase/poke.sql`](supabase/poke.sql)). Needs a shared Supabase project (see [Poke](#poke)).
  - **Timer:** a countdown with presets (1 minute to 1 hour), pause, +1 minute and stop, and Pomodoro: 25 minutes of focus, then a 5-minute break that starts on its own. A sound plays when it ends. With *Turn On Focus*, Pomodoro turns a Focus on for the focus part (see [Focus during Pomodoro](#focus-during-pomodoro)).
  - **Todo** (right of the notch, beside the VPN tab): your own todos on the left, and on the right the todos you share with a friend, picked by name at the top. Both of you can add to a shared list, tick its todos off and delete them, and a change shows on the other Mac at once; a todo your friend added shows their name under it. Type and press Enter to add a todo. A time typed into it becomes its date, in Indonesian or English (*Kirim laporan besok jam 10*, *standup Senin jam 9*, *call Budi tomorrow 3pm*): a chip under the field shows the time it read, and its × keeps the words instead. The calendar in the field sets one by hand (type or step it, or pick *Today*, *Tonight* or *Tomorrow*). The list is grouped into *Late*, *Today*, *Upcoming* and *Anytime*, with the ticked-off ones folded under *Done*; a todo's time shows as a chip, orange within the hour and red once it's past. Double-click a todo to edit it (a time typed there moves it), hover for the clock to move it to *In 1 Hour*, *Tonight*, *Tomorrow* or *Next Week* (or remove its date), and right-click for all of it plus *Copy*. When an open todo's time comes, yours or one shared with any friend, the notch drops down with it and a sound plays (Glass, or pick another in ⚙ → *Todo Sound*, the same way as the poke sound), also during a Focus; click the banner to open the Todo tab. Open todos with a date come first, soonest on top. Click a todo's circle to tick it off, hover over it for the trash can to delete it, and *Clear Done* removes the ticked-off ones. Todos are kept in the Supabase project Poke uses, so Poke has to be set up first, and the project needs [`supabase/todo.sql`](supabase/todo.sql) (see [Todo](#todo)).
  - **VPN** (right of the notch, next to the pin): the profiles in the [Pritunl](https://pritunl.com) client as square tiles. Click a tile to connect, and again to disconnect: a connected one has a green border and shows how long it's been up (hover for the address it got), one connecting an orange border, and one disconnecting turns red. A profile that needs a PIN takes it from `PRITUNL_PIN` in your zsh config (e.g. `PRITUNL_PIN=123456` in `~/.zshrc`; it needn't be exported, which keeps it out of the environment of programs started from a terminal), and uses it for every profile, since a Pritunl PIN belongs to the user. Otherwise it asks for the PIN on each connect and doesn't keep it. The app never stores the PIN itself, not in the keychain and not on disk; keep `~/.zshrc` readable by you only (`chmod 600 ~/.zshrc`). While a VPN is connected a green lock shows beside the notch, and the notch drops down when a VPN connects or drops, also one started in the Pritunl app. Needs the Pritunl client in `/Applications`; the notch uses its command-line tool, so Pritunl's own service does the connecting. The PIN is typed in at the tool's password prompt, never passed as a command-line argument, where other processes could read it.

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

The 5-hour and weekly limits are read from Anthropic every 2 minutes, from the same usage endpoint Claude Code's `/usage` reads, so they're right however you use Claude Code (terminal, desktop app, IDE). The app signs in with Claude Code's own token, read from the login keychain (`Claude Code-credentials`) through `security`, as Claude Code reads it; the token goes to api.anthropic.com only and is never logged, kept or refreshed by the app. If Claude Code's sign-in has expired, the read waits until Claude Code renews it. The endpoint isn't documented, so it may change; the app then falls back to the status line.

The status line is the fallback, and it only works while Claude Code runs in a terminal. To set it up:

1. Copy the script:

   ```sh
   cp scripts/claude-statusline.sh ~/.claude/dynamic-island-statusline.sh
   chmod 700 ~/.claude/dynamic-island-statusline.sh
   ```

2. Add this to `~/.claude/settings.json`:

   ```json
   "statusLine": { "type": "command", "command": "~/.claude/dynamic-island-statusline.sh" }
   ```

On each refresh the script saves the status JSON to `~/Library/Application Support/DynamicIsland/claude-status.json`, where the app reads it. It also prints the model and usage bars as the Claude Code status line. Token counts for today are read from Claude Code's local transcripts in `~/.claude/projects`. Without a fresh read from Anthropic, limits the status line saved before your latest Claude reply are out of date; the notch then hides them and shows today's tokens instead.

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
3. In the *SQL Editor*, run [`supabase/poke.sql`](supabase/poke.sql). It creates the tables and the rules that keep everyone to their own data. For the Todo tab, also run [`supabase/todo.sql`](supabase/todo.sql).
4. In *Project Settings → API Keys*, copy the project URL and the anon (or publishable) key.

Then everyone, on their own Mac: open the notch's **Poke** tab, paste the URL and key, click *Connect* and enter a name. Each person gets a friend code like `K7QX-M2PA`; entering a friend's code makes you friends both ways. Share the URL and key privately with friends (not in this repo): the key is meant to ship in apps, but it lets anyone who has it sign up to your project.

- What's stored: in Supabase, each person's name and friend code, who is friends with whom, and pokes (sender, recipient, message) for a week. To empty the pokes every night instead, also run [`supabase/nightly-cleanup.sql`](supabase/nightly-cleanup.sql) (23:59 Jakarta time; change the schedule for another time zone). On the Mac, the URL and key in the app's preferences and the sign-in in `~/Library/Application Support/<bundle id>/Poke/`, readable by the user only.
- Pokes arrive right away while the app runs. Pokes sent while it was off show when it comes back; those older than 10 minutes go only to the Alerts tab.
- A friend is online while their Dynamic Island runs and is connected to Poke; quitting, sleeping or losing the network takes them offline within a minute or so. A friend is in a meeting while a timed event they haven't declined is on in their calendar, or they're in a Google Meet call; only that yes or no is shared, never the meeting itself. The song (title and artist, from Spotify or Music, not YouTube) is shared while it plays, unless you turn off ⚙ → *Share What I'm Playing*. Every connected app can see which user IDs are online and in a meeting, but only friends can put a name to one. Nothing about it is stored.
- At most 10 pokes a minute per person, and messages up to 100 characters.
- Supabase pauses free projects after about a week without use. If the Poke tab says it can't reach Supabase, restore the project in the dashboard.
- *Change Project* forgets the project and this Mac's sign-in. Setting up again makes a new friend code, so friends have to add you again.

## Todo

The Todo tab keeps each person's todos in the same Supabase project as Poke, under the same anonymous sign-in. Whoever set up the project runs [`supabase/todo.sql`](supabase/todo.sql) in its *SQL Editor*; running it again is safe and brings an older version up to date. Until then the tab says so.

- Your own todos are yours only. A shared todo belongs to the two of you: both can see it, tick it off and delete it, and only friends can share. Row level security keeps everyone else out.
- Shared todos change on both Macs at once through Realtime.
- A todo is up to 200 characters, with an optional date and time it's due, and each person can add up to 200 todos. The database records who added each, when, and when it was ticked off.
- The lists belong to this Mac's sign-in: *Change Project* in the Poke tab, or losing `~/Library/Application Support/<bundle id>/Poke/`, starts with empty lists. Todos shared with a friend you remove stay in both lists until one of you deletes them.

## Focus during Pomodoro

macOS has no API to turn a Focus on, so the app runs two shortcuts you make once in the Shortcuts app:

1. A shortcut named **Dynamic Island Focus On** with the *Set Focus* action: turn Do Not Disturb (or another Focus) on.
2. A shortcut named **Dynamic Island Focus Off** with the *Set Focus* action: turn it off.

Then turn on *Turn On Focus* in the Timer tab. If a shortcut is missing, the app says which one in the Alerts tab. Quitting the app during focus turns the Focus off.

## How it reads volume, brightness and headphones

- Volume comes from Core Audio, so the menu bar slider and other apps' changes show too.
- Brightness has no public API: the app reads it through the private DisplayServices framework when a brightness key is pressed. A macOS update may break it; the rest of the app keeps working.
- Headphones are noticed when macOS switches the sound output to them, so the app needs no Bluetooth access. Battery levels come from `system_profiler`.
