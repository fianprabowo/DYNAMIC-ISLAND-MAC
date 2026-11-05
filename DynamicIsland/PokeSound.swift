import AppKit
import UniformTypeIdentifiers

/// The sound a poke plays when it arrives: one of macOS's alert sounds, or a sound of your own.
/// Your own sounds live in ~/Library/Sounds, on this Mac only, where macOS finds them by name.
enum PokeSound {
    static let key = "pokeSound"
    static let defaultName = "Ping"

    private static let audioExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "mp3", "m4a", "m4r"]
    private static let systemFolder = URL(fileURLWithPath: "/System/Library/Sounds")
    private static var userFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds")
    }
    /// Keeps the sound alive while it plays.
    private static var player: NSSound?

    static var name: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultName }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var systemNames: [String] { names(in: systemFolder) }
    static var customNames: [String] { names(in: userFolder) }

    private static func names(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Plays the chosen sound, or Ping if it's gone.
    static func play(_ soundName: String = name) {
        player?.stop()
        player = sound(named: soundName) ?? NSSound(named: defaultName)
        player?.play()
    }

    /// Looks in ~/Library/Sounds first, so a replaced file plays its new sound.
    private static func sound(named soundName: String) -> NSSound? {
        let custom = (try? FileManager.default.contentsOfDirectory(at: userFolder, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == soundName && audioExtensions.contains($0.pathExtension.lowercased()) }
        if let custom {
            return NSSound(contentsOf: custom, byReference: true)
        }
        return NSSound(named: soundName)
    }

    static func stop() {
        player?.stop()
        player = nil
    }

    // MARK: Trying sounds out

    /// The Settings submenu that lists the sounds; resting on one plays it.
    static let menuTitle = "Poke Sound"
    /// How long the pointer rests on a sound before it plays, so sweeping past doesn't.
    private static let hoverDelay: TimeInterval = 0.2
    private static var observers: [NSObjectProtocol] = []
    private static weak var watchedMenu: NSMenu?
    private static var hoverTimer: Timer?
    private static var highlighted: String?
    private static var highlightedSince = Date()
    private static var playedHighlight = false

    /// macOS menus don't tell SwiftUI what's under the pointer, so while the Settings menu is open
    /// the sound submenu's highlighted item is checked a few times a second.
    static func previewOnHover() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, menu.item(withTitle: menuTitle)?.submenu != nil else { return }
                watch(menu)
            }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { note in
            let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu, menu === watchedMenu else { return }
                stopWatching()
            }
        })
    }

    private static func watch(_ menu: NSMenu) {
        stopWatching()
        watchedMenu = menu
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { checkHighlight() }
        }
        // Menus track the pointer in their own run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private static func stopWatching() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        watchedMenu = nil
        if highlighted != nil {
            stop()
        }
        highlighted = nil
    }

    private static func checkHighlight() {
        let item = watchedMenu?.item(withTitle: menuTitle)?.submenu?.highlightedItem
        let title = item.flatMap { $0.submenu == nil && $0.isEnabled ? $0.title : nil }
        if title != highlighted {
            if highlighted != nil {
                stop()
            }
            highlighted = title
            highlightedSince = Date()
            playedHighlight = false
        } else if let title, !playedHighlight, Date().timeIntervalSince(highlightedSince) >= hoverDelay {
            playedHighlight = true
            // Only sounds play, not "Choose Sound File…".
            if (customNames + systemNames).contains(title) {
                play(title)
            }
        }
    }

    static func choose(_ soundName: String) {
        name = soundName
        play(soundName)
    }

    /// Copies an audio file you pick into ~/Library/Sounds and uses it for pokes.
    static func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Poke Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
            let destination = userFolder.appending(path: source.lastPathComponent)
            if destination.standardizedFileURL != source.standardizedFileURL {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            choose(destination.deletingPathExtension().lastPathComponent)
        } catch {
            NSSound.beep()
        }
    }
}
