import AppKit
import Combine

/// Google Meet running in Chrome, watched and controlled from the notch: the microphone, the
/// camera, Join now and Leave. Like YouTube, it uses JavaScript sent over AppleScript, which
/// Chrome only runs after View › Developer › Allow JavaScript from Apple Events is turned on for
/// the profile the meeting is in; without it, only the meeting's name and tab are known.
class MeetController: ObservableObject {
    struct Meeting: Equatable {
        /// Chrome's tab id, which it reports as text.
        let tab: String
        /// The meeting code from the link, like "abc-defg-hij", to match a calendar event.
        let code: String
        let title: String
        /// False on the screen before joining.
        let isInCall: Bool
        /// Whether Join now (or Ask to join) is on the screen.
        let canJoin: Bool
        /// Nil when Meet doesn't show that button (or JavaScript is off).
        let isMicrophoneOn: Bool?
        let isCameraOn: Bool?
        /// False when Chrome refuses JavaScript from Apple Events for the tab.
        let isScriptable: Bool
        /// The tab's own title, which Chrome's window title starts with while the tab is showing.
        let tabTitle: String
        /// Chrome's tab strip and toolbar above the page, in points; 0 when unknown.
        let browserBarHeight: Double
    }

    @Published private(set) var meeting: Meeting?
    /// When the call was first seen joined, for how long it has run.
    @Published private(set) var callStartedAt: Date?

    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    deinit {
        pollTask?.cancel()
    }

    func toggleMicrophone() {
        command("var b = \(Self.microphoneButton); if (b) { b.click(); }")
    }

    func toggleCamera() {
        command("var b = \(Self.cameraButton); if (b) { b.click(); }")
    }

    func join() {
        command("var b = \(Self.joinButton); if (b) { b.click(); }")
    }

    func leave() {
        command("var b = \(Self.leaveButton); if (b) { b.click(); }")
    }

    /// Brings Chrome to the front with the meeting's tab selected.
    func reveal() {
        guard let meeting else { return }
        Task { await YouTubeBridge.reveal(tab: meeting.tab) }
    }

    /// Opens a Meet link in Chrome when it's installed, where the notch can control it.
    static func open(_ url: URL) {
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MediaPlayerApp.chrome.rawValue) {
            NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func isMeetLink(_ url: URL) -> Bool {
        url.host?.lowercased() == "meet.google.com"
    }

    private func command(_ script: String) {
        guard let tab = meeting?.tab else { return }
        Task {
            await Self.run(script, in: tab)
            // Meet takes a moment to update its buttons.
            try? await Task.sleep(for: .seconds(0.4))
            await refresh()
        }
    }

    private func refresh() async {
        guard MediaPlayerApp.chrome.isRunning else {
            update(nil)
            return
        }
        let meetings = await Self.meetings()
        update(meetings.first(where: \.isInCall) ?? meetings.first)
    }

    private func update(_ newMeeting: Meeting?) {
        if newMeeting?.isInCall == true {
            if callStartedAt == nil || meeting?.code != newMeeting?.code {
                callStartedAt = Date()
            }
        } else {
            callStartedAt = nil
        }
        if meeting != newMeeting {
            meeting = newMeeting
        }
    }

    // The scripts go inside AppleScript strings, so they use single quotes only. Meet's buttons are
    // found by their data-is-muted state and labels (English or Indonesian), then by their order.
    private static let toggles = "Array.prototype.slice.call(document.querySelectorAll('[data-is-muted]'))"
    private static func labelled(_ pattern: String, index: Int) -> String {
        "(\(toggles).filter(function (b) { return /\(pattern)/i.test((b.getAttribute('aria-label') || '') + (b.getAttribute('data-tooltip') || '')); })[0] || \(toggles)[\(index)])"
    }
    private static let microphoneButton = labelled("microphone|mikrofon", index: 0)
    private static let cameraButton = labelled("camera|kamera", index: 1)
    private static let leaveButton = "(document.querySelector('[jsname=CQylAd]') || Array.prototype.filter.call(document.querySelectorAll('button[aria-label]'), function (b) { return /leave call|tinggalkan panggilan|keluar dari panggilan/i.test(b.getAttribute('aria-label')); })[0])"
    private static let joinButton = "Array.prototype.filter.call(document.querySelectorAll('button'), function (b) { return /join now|ask to join|gabung sekarang|minta bergabung/i.test(b.innerText || ''); })[0]"

    private static let snapshotScript = "(function () { var mic = \(microphoneButton); var cam = \(cameraButton); return JSON.stringify({ inCall: !!\(leaveButton), canJoin: !!\(joinButton), mic: mic ? mic.getAttribute('data-is-muted') !== 'true' : null, cam: cam ? cam.getAttribute('data-is-muted') !== 'true' : null, bar: window.outerHeight - window.innerHeight }); })()"

    private struct Info: Decodable {
        let inCall: Bool
        let canJoin: Bool
        let mic: Bool?
        let cam: Bool?
        let bar: Double
    }

    /// Every Meet tab with a meeting code, in window and tab order.
    private static func meetings() async -> [Meeting] {
        let source = """
        tell application "Google Chrome"
            set found to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u starts with "https://meet.google.com/" then
                        set info to ""
                        try
                            set info to execute t javascript "\(snapshotScript)"
                        end try
                        set end of found to {id of t as text, title of t, u, info}
                    end if
                end repeat
            end repeat
            return found
        end tell
        """
        guard let result = await AppleScriptRunner.run(source), result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { index in
            guard let item = result.atIndex(index), item.numberOfItems == 4,
                  let tab = item.atIndex(1)?.stringValue,
                  let url = item.atIndex(3)?.stringValue.flatMap({ URL(string: $0) }),
                  let code = meetingCode(in: url) else { return nil }
            let tabTitle = item.atIndex(2)?.stringValue ?? ""
            let title = cleanTitle(tabTitle, code: code)
            guard let data = item.atIndex(4)?.stringValue?.data(using: .utf8),
                  let info = try? JSONDecoder().decode(Info.self, from: data) else {
                return Meeting(tab: tab, code: code, title: title, isInCall: false, canJoin: false,
                               isMicrophoneOn: nil, isCameraOn: nil, isScriptable: false, tabTitle: tabTitle, browserBarHeight: 0)
            }
            return Meeting(tab: tab, code: code, title: title, isInCall: info.inCall, canJoin: info.canJoin,
                           isMicrophoneOn: info.mic, isCameraOn: info.cam, isScriptable: true,
                           tabTitle: tabTitle, browserBarHeight: max(0, info.bar))
        }
    }

    /// "abc-defg-hij" from links like meet.google.com/abc-defg-hij; nil for Meet's home page.
    nonisolated static func meetingCode(in url: URL) -> String? {
        url.pathComponents.last { $0.wholeMatch(of: /[a-z]{3}-[a-z]{4}-[a-z]{3}/) != nil }
    }

    /// "Meet - Weekly sync" → "Weekly sync"; the code when the title has nothing else.
    private static func cleanTitle(_ title: String, code: String) -> String {
        let name = title.replacing(/^Meet\s*[-–]\s*/, with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "Meet" ? code : name
    }

    private static func run(_ script: String, in tab: String) async {
        await AppleScriptRunner.run("""
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as text) is "\(tab)" then
                        execute t javascript "\(script)"
                        return
                    end if
                end repeat
            end repeat
        end tell
        """)
    }
}
