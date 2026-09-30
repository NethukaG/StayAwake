import SwiftUI
import AppKit
import Combine
import Sparkle
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

// MARK: - Config

enum Config {
    static let bundleID = "com.nethuka.stayawake"
    static let sudoersPath = "/etc/sudoers.d/staysafe-clamshell"
    static let pmsetPath = "/usr/bin/pmset"
    static let defaultClamshellMinutes = 15
    static let neverValue = -1
    static let durationOptions: [Int] = [5, 15, 30, 60, Config.neverValue]
    static let hasCompletedSetupKey = "hasCompletedSetup"
}

private func durationLabel(_ minutes: Int) -> String {
    if minutes == Config.neverValue { return "Never" }
    if minutes < 60 { return "\(minutes) Minutes" }
    return minutes == 60 ? "1 Hour" : "\(minutes / 60) Hours"
}

/// An app StayAwake watches for. While any watched app is running, StayAwake turns itself
/// on automatically; once none of them are running, it turns itself back off -- but only if
/// it was that auto-trigger that turned it on in the first place (see `autoEngaged` on the
/// manager). A manual toggle always takes precedence over this.
struct WatchedApp: Codable, Equatable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
}

// MARK: - Manager

@MainActor
final class StayAwakeManager: ObservableObject {
    @Published var isOn: Bool = false
    @Published var lidClosed: Bool = false
    @Published var remainingSeconds: Int? = nil
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var clamshellHelperInstalled: Bool = FileManager.default.fileExists(atPath: Config.sudoersPath)
    @Published var notificationsAuthorized: Bool = false
    @Published var clamshellMinutes: Int = {
        let stored = UserDefaults.standard.object(forKey: "clamshellMinutes") as? Int
        return stored ?? Config.defaultClamshellMinutes
    }()

    // Apps that auto-engage Stay Awake while any of them is running. See WatchedApp's doc
    // comment and evaluateAutoTrigger() below for the actual rules.
    @Published var watchedApps: [WatchedApp] = {
        guard let data = UserDefaults.standard.data(forKey: "watchedApps"),
              let decoded = try? JSONDecoder().decode([WatchedApp].self, from: data) else { return [] }
        return decoded
    }()
    /// True when the CURRENT isOn=true was caused by the auto-trigger rather than the user
    /// clicking the toggle. Used so a watched app quitting only turns Stay Awake back off if
    /// nothing else (i.e. the user) turned it on independently in the meantime.
    @Published private(set) var autoEngaged = false

    // TEMP DEBUG ONLY: live popover position nudge, set from the Position Tuner window.
    // Default baked in from tuning: offsetX 7, offsetY 18.
    @Published var popoverOffsetX: CGFloat = 7
    @Published var popoverOffsetY: CGFloat = 18

    private var idleAssertionID: IOPMAssertionID = 0
    private var hasIdleAssertion = false
    private var lidPollTimer: Timer?
    private var countdownTimer: Timer?
    private var clamshellArmed = false
    private var unlockObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var anyWatchedAppWasRunning = false

    init() {
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleUnlock() }
        }
        setupAppWatching()
    }

    deinit {
        if let unlockObserver { DistributedNotificationCenter.default().removeObserver(unlockObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    // MARK: Toggle

    func toggle() {
        isOn.toggle()
        // Any direct interaction with the toggle, on or off, means whatever happens next is
        // no longer attributable to the auto-trigger -- in particular, turning off manually
        // while a watched app is still running must NOT get auto-re-engaged by that same app
        // still running; it only re-engages the next time a watched app freshly launches.
        autoEngaged = false
        if isOn { start() } else { stop() }
    }

    private func start() {
        beginIdleAssertion()
        lidClosed = isLidClosedNow()
        lidPollTimer?.invalidate()
        lidPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLid() }
        }
        if lidClosed { armClamshell() }
    }

    private func stop() {
        endIdleAssertion()
        lidPollTimer?.invalidate(); lidPollTimer = nil
        disarmClamshell()
        remainingSeconds = nil
        lidClosed = isLidClosedNow()
    }

    // MARK: Lid polling

    private func pollLid() {
        let closed = isLidClosedNow()
        if closed == lidClosed { return }
        lidClosed = closed
        if closed { armClamshell() }
    }

    private func handleUnlock() {
        guard isOn else { return }
        if !lidClosed { disarmClamshell() }
    }

    // MARK: Clamshell (lid-closed) layer

    private func armClamshell() {
        guard !clamshellArmed else { return }
        guard clamshellHelperInstalled else {
            notify(title: "Stay Awake", body: "Lid closed, but lid-closed mode isn't set up yet. The Mac will sleep normally.")
            return
        }
        clamshellArmed = true
        runPrivilegedPmset(disable: true)

        if clamshellMinutes == Config.neverValue {
            remainingSeconds = nil
            return
        }
        remainingSeconds = clamshellMinutes * 60
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown() }
        }
    }

    private func disarmClamshell() {
        guard clamshellArmed else { return }
        clamshellArmed = false
        countdownTimer?.invalidate(); countdownTimer = nil
        remainingSeconds = nil
        runPrivilegedPmset(disable: false)
    }

    private func tickCountdown() {
        guard var remaining = remainingSeconds else { return }
        remaining -= 1
        if remaining <= 0 {
            countdownTimer?.invalidate(); countdownTimer = nil
            remainingSeconds = nil
            clamshellArmed = false
            clearDisableSleepWithVerification()
            endIdleAssertion()
            forceSleepNow()
            isOn = false
            lidPollTimer?.invalidate(); lidPollTimer = nil
            notify(title: "Stay Awake", body: "\(durationLabel(clamshellMinutes)) with the lid closed. Turned off and let the Mac sleep for safety.")
        } else {
            remainingSeconds = remaining
        }
    }

    private func forceSleepNow() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "tell application \"System Events\" to sleep"]
        try? task.run()
    }

    @discardableResult
    private func runPrivilegedPmset(disable: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", Config.pmsetPath, "-a", "disablesleep", disable ? "1" : "0"]
        let pipe = Pipe()
        task.standardOutput = pipe; task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Reads the live disablesleep state directly from pmset (no privilege needed to read).
    /// Used to verify a clear actually took effect, rather than trusting a silent success.
    private func currentSleepDisabledState() -> Bool? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
                return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
            }
            return false
        } catch {
            return nil
        }
    }

    /// Clears the disablesleep override and verifies it actually cleared, retrying a couple
    /// of times and surfacing a notification if it's still stuck. This override blocks ALL
    /// sleep, not just idle sleep -- so if clearing it silently failed, forceSleepNow() below
    /// would not actually put the Mac to sleep, defeating the whole point of this cutoff.
    private func clearDisableSleepWithVerification() {
        for attempt in 0..<3 {
            runPrivilegedPmset(disable: false)
            if currentSleepDisabledState() != true { return }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) }
        }
        notify(title: "Stay Awake", body: "Could not confirm sleep was re-enabled. If your Mac won't sleep on its own, run in Terminal: sudo pmset -a disablesleep 0")
    }

    /// Best-effort synchronous cleanup for app termination (quit, or the OS calling this
    /// during a crash/logout): never leave the Mac permanently unable to sleep just because
    /// the app stopped running before it could disarm the override itself.
    func disarmForTermination() {
        guard clamshellArmed else { return }
        clamshellArmed = false
        runPrivilegedPmset(disable: false)
    }

    /// Startup self-heal: if a previous crash or force-quit left disablesleep stuck at 1
    /// before the app could clean up, clear it now rather than leaving the Mac unable to
    /// sleep until someone notices and fixes it by hand.
    func selfHealStaleDisableSleep() {
        guard clamshellHelperInstalled else { return }
        if currentSleepDisabledState() == true {
            runPrivilegedPmset(disable: false)
            notify(title: "Stay Awake", body: "Cleared a leftover sleep-prevention setting left over from a previous session.")
        }
    }

    // MARK: Auto-enable for watched apps

    private func setupAppWatching() {
        let nc = NSWorkspace.shared.notificationCenter
        let launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutoTrigger() }
        }
        let termObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateAutoTrigger() }
        }
        workspaceObservers = [launchObs, termObs]
        // Deliberately left false here (rather than pre-seeded from the current running
        // apps) so that if a watched app is already open when Stay Awake launches, the very
        // first evaluateAutoTrigger() call below sees a false-to-true rising edge and
        // auto-engages, instead of silently doing nothing just because that app "was already
        // running before we started watching."
        evaluateAutoTrigger()
    }

    private func isAnyWatchedAppRunning() -> Bool {
        guard !watchedApps.isEmpty else { return false }
        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return watchedApps.contains { runningIDs.contains($0.bundleID) }
    }

    /// The whole auto-trigger rule set lives here, run after every relevant change (an app
    /// launching or quitting, or the watch list itself changing): auto-ON on a false-to-true
    /// rising edge (unless already on for some other reason), auto-OFF on a true-to-false
    /// falling edge but ONLY if this manager was the one that turned it on (autoEngaged) --
    /// never turn off something the user turned on manually themselves.
    private func evaluateAutoTrigger() {
        let running = isAnyWatchedAppRunning()
        defer { anyWatchedAppWasRunning = running }

        if running && !anyWatchedAppWasRunning {
            guard !isOn else { return }
            isOn = true
            autoEngaged = true
            start()
        } else if !running && anyWatchedAppWasRunning {
            guard isOn, autoEngaged else { return }
            isOn = false
            autoEngaged = false
            stop()
        }
    }

    func addWatchedApp(bundleID: String, displayName: String) {
        guard !watchedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        watchedApps.append(WatchedApp(bundleID: bundleID, displayName: displayName))
        persistWatchedApps()
        evaluateAutoTrigger()
    }

    func removeWatchedApp(bundleID: String) {
        watchedApps.removeAll { $0.bundleID == bundleID }
        persistWatchedApps()
        evaluateAutoTrigger()
    }

    private func persistWatchedApps() {
        if let data = try? JSONEncoder().encode(watchedApps) {
            UserDefaults.standard.set(data, forKey: "watchedApps")
        }
    }

    // MARK: Duration setting

    func setClamshellMinutes(_ minutes: Int) {
        clamshellMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "clamshellMinutes")
        // If currently counting down, re-apply the new duration immediately.
        guard clamshellArmed else { return }
        countdownTimer?.invalidate(); countdownTimer = nil
        if minutes == Config.neverValue {
            remainingSeconds = nil
        } else {
            remainingSeconds = minutes * 60
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickCountdown() }
            }
        }
    }

    // MARK: IOKit assertion (lid-open idle sleep prevention)

    private func beginIdleAssertion() {
        guard !hasIdleAssertion else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Stay Awake is enabled" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            idleAssertionID = id
            hasIdleAssertion = true
        }
    }

    private func endIdleAssertion() {
        guard hasIdleAssertion else { return }
        IOPMAssertionRelease(idleAssertionID)
        hasIdleAssertion = false
    }

    private func isLidClosedNow() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
            return false
        }
        let value = cf.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    // MARK: Setup / teardown of the privileged helper

    func installClamshellHelper(completion: @escaping (Bool) -> Void) {
        let user = NSUserName()
        // A macOS local short username should only ever contain these characters, but this
        // string is about to be embedded, unquoted-by-us, into a root-owned sudoers rule --
        // validate it first rather than trusting it, so a weird username can never turn into
        // a sudoers/shell injection.
        let allowedUsernameChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowedUsernameChars.contains) else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let line = "\(user) ALL=(root) NOPASSWD: \(Config.pmsetPath) -a disablesleep 1, \(Config.pmsetPath) -a disablesleep 0"
        let shell = """
        TMP=$(mktemp) && echo '\(line)' > "$TMP" && chmod 440 "$TMP" && /usr/sbin/visudo -c -f "$TMP" && mv "$TMP" \(Config.sudoersPath) && chown root:wheel \(Config.sudoersPath)
        """
        let escaped = shell.replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Stay Awake needs one-time permission to keep the Mac awake with the lid closed.\""

        // Runs the admin-privileges prompt + shell work off the main thread: this call blocks
        // until the user answers the password dialog, which could otherwise freeze the whole
        // app's UI (menu, toggle, everything) for as long as that dialog is up.
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", osa]
            let pipe = Pipe()
            task.standardOutput = pipe; task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // fall through; installed-check below will correctly report failure
            }
            let installed = FileManager.default.fileExists(atPath: Config.sudoersPath)
            DispatchQueue.main.async {
                self.clamshellHelperInstalled = installed
                completion(installed)
            }
        }
    }

    func removeClamshellHelper(completion: @escaping (Bool) -> Void) {
        let shell = "rm -f \(Config.sudoersPath)"
        let osa = "do shell script \"\(shell)\" with administrator privileges"

        // Same reasoning as installClamshellHelper: don't block the main thread on the
        // admin-privileges dialog.
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", osa]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // fall through; stillThere check below will correctly report failure
            }
            let stillThere = FileManager.default.fileExists(atPath: Config.sudoersPath)
            DispatchQueue.main.async {
                self.clamshellHelperInstalled = !stillThere
                completion(!stillThere)
            }
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: Notifications (used live by the first-run setup flow)

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationsAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }

    func requestNotificationPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.notificationsAuthorized = granted
                completion(granted)
            }
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

// MARK: - Popover UI (left click)

struct ToggleSwitch: View {
    @Binding var isOn: Bool
    var action: () -> Void

    private let width: CGFloat = 44
    private let height: CGFloat = 24
    private let knobSize: CGFloat = 20
    private let knobInset: CGFloat = 2

    // Matches the pattern from AppCoda's ToggleStyle guide (appcoda.com/swiftui-togglestyle):
    // wrap the state mutation itself in withAnimation, rather than relying only on a passive
    // .animation(value:) modifier. `action` mutates an @Published property on an external
    // ObservableObject, outside this view's own transaction, and the implicit modifier alone
    // was not reliably picking that up while hosted in an NSPanel -- the knob was snapping
    // instantly instead of sliding. Wrapping the call here fixes that at the source.
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                action()
            }
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(isOn ? Color.green : Color(white: 0.32))
                    .frame(width: width, height: height)
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(radius: 1)
                    .padding(knobInset)
                    // A continuous offset, not a ZStack alignment switch -- alignment changes
                    // are not interpolated by SwiftUI, so the knob would just jump to the new
                    // side instead of sliding. This is what gives it the native, WiFi-toggle-like
                    // glide instead of an instant snap.
                    .offset(x: isOn ? (width - knobSize - knobInset * 2) : 0)
            }
        }
        .buttonStyle(.plain)
        // Kept as a fallback for when isOn changes from outside this button entirely (auto-enable
        // turning it on because a watched app launched, for example), so that still animates too.
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isOn)
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct PopoverBubbleShape: Shape {
    var cornerRadius: CGFloat = 22
    var arrowWidth: CGFloat = 20
    var arrowHeight: CGFloat = 10
    var arrowCornerRadius: CGFloat = 5

    // A single continuous outline, built by rounding every vertex of the underlying
    // polygon (the arrow's tip + both base corners, plus the body's four corners).
    // Rounding the arrow's own corners (not just the body's) is what makes it read as
    // a smooth, soft nub instead of a sharp triangular notch.
    func path(in rect: CGRect) -> Path {
        let bTop = rect.minY + arrowHeight
        let bodyRect = CGRect(x: rect.minX, y: bTop, width: rect.width, height: rect.height - arrowHeight)
        let r = min(cornerRadius, min(bodyRect.width, bodyRect.height) / 2)
        let ar = min(arrowCornerRadius, arrowWidth / 2, arrowHeight)
        let cx = rect.midX

        let vertices: [(point: CGPoint, radius: CGFloat)] = [
            (CGPoint(x: cx - arrowWidth / 2, y: bTop), ar),
            (CGPoint(x: cx, y: rect.minY), ar),
            (CGPoint(x: cx + arrowWidth / 2, y: bTop), ar),
            (CGPoint(x: bodyRect.maxX, y: bTop), r),
            (CGPoint(x: bodyRect.maxX, y: bodyRect.maxY), r),
            (CGPoint(x: bodyRect.minX, y: bodyRect.maxY), r),
            (CGPoint(x: bodyRect.minX, y: bTop), r),
        ]

        func norm(_ v: CGPoint) -> CGPoint {
            let len = (v.x * v.x + v.y * v.y).squareRoot()
            return len == 0 ? .zero : CGPoint(x: v.x / len, y: v.y / len)
        }

        var p = Path()
        let n = vertices.count
        for i in 0..<n {
            let prev = vertices[(i - 1 + n) % n].point
            let (vertex, radius) = vertices[i]
            let next = vertices[(i + 1) % n].point
            let toPrev = norm(CGPoint(x: prev.x - vertex.x, y: prev.y - vertex.y))
            let toNext = norm(CGPoint(x: next.x - vertex.x, y: next.y - vertex.y))
            let entry = CGPoint(x: vertex.x + toPrev.x * radius, y: vertex.y + toPrev.y * radius)
            let exit = CGPoint(x: vertex.x + toNext.x * radius, y: vertex.y + toNext.y * radius)
            if i == 0 {
                p.move(to: entry)
            } else {
                p.addLine(to: entry)
            }
            p.addQuadCurve(to: exit, control: vertex)
        }
        p.closeSubpath()
        return p
    }
}

struct PopoverContent: View {
    @ObservedObject var manager: StayAwakeManager
    var onSettings: () -> Void

    private let arrowHeight: CGFloat = 10
    private let cornerRadius: CGFloat = 22

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBlur(material: .popover, blendingMode: .behindWindow)
                .clipShape(PopoverBubbleShape(cornerRadius: cornerRadius, arrowWidth: 20, arrowHeight: arrowHeight))
            PopoverBubbleShape(cornerRadius: cornerRadius, arrowWidth: 20, arrowHeight: arrowHeight)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)

            VStack(spacing: 0) {
                HStack {
                    Text("Stay Awake")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    ToggleSwitch(isOn: $manager.isOn) { manager.toggle() }
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .help("Settings")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if let remaining = manager.remainingSeconds {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "lock.laptopcomputer")
                            .font(.caption2)
                        Text("Sleeps in \(formatTime(remaining)) unless you unlock")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                } else if manager.isOn && manager.lidClosed && manager.clamshellMinutes == Config.neverValue {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "lock.laptopcomputer")
                            .font(.caption2)
                        Text("Lid closed, staying awake")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                } else if manager.isOn && manager.autoEngaged {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                        Text("Auto-enabled for a running app")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .padding(.top, arrowHeight)
        }
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// TEMP DEBUG ONLY: sliders to find the right popover offset, then report the numbers back.
struct PositionTunerView: View {
    @ObservedObject var manager: StayAwakeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Popover Position Tuner")
                .font(.headline)
            Text("Drag until the popover sits where you want it, then send both numbers back.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Horizontal (+ = right, − = left): \(Int(manager.popoverOffsetX))")
                    .font(.system(.body, design: .monospaced))
                Slider(value: $manager.popoverOffsetX, in: -150...150, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Vertical (+ = up, − = down): \(Int(manager.popoverOffsetY))")
                    .font(.system(.body, design: .monospaced))
                Slider(value: $manager.popoverOffsetY, in: -150...150, step: 1)
            }

            Divider()

            Text("offsetX: \(Int(manager.popoverOffsetX))   offsetY: \(Int(manager.popoverOffsetY))")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Button("Reset to 0, 0") {
                manager.popoverOffsetX = 0
                manager.popoverOffsetY = 0
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

// MARK: - App delegate (owns status item, popover, menu)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = StayAwakeManager()
    // startingUpdater: true means it begins its own periodic background check (interval set
    // by SUScheduledCheckInterval in Info.plist) as soon as this is created; "Check for
    // Updates..." below just triggers an on-demand check on top of that.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var statusItem: NSStatusItem!
    private var popoverPanel: NSPanel!
    private var cancellable: AnyObject?
    private var outsideClickMonitor: Any?
    private var tunerWindow: NSWindow? // TEMP DEBUG ONLY
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(
            rootView: PopoverContent(manager: manager, onSettings: { [weak self] in self?.presentSettingsMenu() })
        )
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = hosting
        popoverPanel = panel

        // Repaint the icon, and resize/reposition the popover if its content actually needs
        // it (an extra row appeared, or the tuner offset changed), whenever relevant state
        // changes. This must not touch the window frame on every change unconditionally --
        // doing so was forcing a synchronous AppKit layout pass on the hosted SwiftUI content
        // right in the middle of the toggle's own animation, which cut it short and made the
        // knob look like it was snapping instantly instead of sliding.
        let observer = manager.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.updateIcon()
                self?.resizeAndRepositionPopoverIfNeeded()
            }
        }
        cancellable = observer as AnyObject

        // If a previous run crashed or was force-quit mid-countdown, it may have left the
        // Mac permanently unable to sleep. Check and fix that now, on every launch.
        manager.selfHealStaleDisableSleep()

        // First-run guided setup, shown once. Reachable again later from the right-click menu.
        if !UserDefaults.standard.bool(forKey: Config.hasCompletedSetupKey) {
            showSetupFlow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting (menu Quit, Cmd-Q if ever added, or the OS terminating us on logout)
        // must never leave the lid-closed sleep override stuck on.
        manager.disarmForTermination()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            presentSettingsMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popoverPanel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    // Position purely from the status item button's own screen-space frame, never from
    // whatever window/screen AppKit thinks is "active" -- that heuristic is what was
    // placing this far from the icon when another app was frontmost/fullscreen.
    // TEMP DEBUG: also applies manager.popoverOffsetX/Y from the Position Tuner.
    private func popoverOrigin(contentSize: NSSize) -> NSPoint? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        let buttonFrameOnScreen = buttonWindow.convertToScreen(button.frame)
        let x = buttonFrameOnScreen.midX - contentSize.width / 2 + manager.popoverOffsetX
        let y = buttonFrameOnScreen.minY - contentSize.height - 6 + manager.popoverOffsetY
        return NSPoint(x: x, y: y)
    }

    private func showPopover() {
        popoverPanel.contentViewController?.view.layoutSubtreeIfNeeded()
        let contentSize = popoverPanel.contentViewController?.view.fittingSize ?? NSSize(width: 260, height: 60)
        popoverPanel.setContentSize(contentSize)
        guard let origin = popoverOrigin(contentSize: contentSize) else { return }
        popoverPanel.setFrameOrigin(origin)
        popoverPanel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    // TEMP DEBUG ONLY: live-move the popover as the tuner sliders change.
    // Only actually touches the window frame when the fitting size or target origin has
    // really changed, so a plain on/off toggle (same size, same origin) leaves the panel's
    // frame alone and lets the SwiftUI animation inside it play out undisturbed.
    private func resizeAndRepositionPopoverIfNeeded() {
        guard popoverPanel.isVisible else { return }
        popoverPanel.contentViewController?.view.layoutSubtreeIfNeeded()
        let fittingSize = popoverPanel.contentViewController?.view.fittingSize ?? popoverPanel.frame.size
        if abs(fittingSize.width - popoverPanel.frame.size.width) > 0.5
            || abs(fittingSize.height - popoverPanel.frame.size.height) > 0.5 {
            popoverPanel.setContentSize(fittingSize)
        }
        guard let origin = popoverOrigin(contentSize: popoverPanel.frame.size) else { return }
        if abs(origin.x - popoverPanel.frame.origin.x) > 0.5 || abs(origin.y - popoverPanel.frame.origin.y) > 0.5 {
            popoverPanel.setFrameOrigin(origin)
        }
    }

    // TEMP DEBUG ONLY: opens the slider window and makes sure the popover is visible to nudge.
    private func showPositionTuner() {
        if tunerWindow == nil {
            let hosting = NSHostingController(rootView: PositionTunerView(manager: manager))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Popover Position Tuner (Debug)"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating
            tunerWindow = window
        }
        if !popoverPanel.isVisible { showPopover() }
        NSApp.activate(ignoringOtherApps: true)
        tunerWindow?.makeKeyAndOrderFront(nil)
    }

    private func closePopover() {
        popoverPanel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Let a click back on the status item itself be handled by its own action
            // (togglePopover), rather than closing here and reopening there.
            if let button = self.statusItem.button, let buttonWindow = button.window {
                let buttonFrameOnScreen = buttonWindow.convertToScreen(button.frame)
                if buttonFrameOnScreen.contains(NSEvent.mouseLocation) { return }
            }
            Task { @MainActor in self.closePopover() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func showSetupFlow() {
        if setupWindow == nil {
            let hosting = NSHostingController(
                rootView: SetupFlowView(manager: manager, onFinish: { [weak self] in
                    self?.setupWindow?.close()
                })
            )
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.center()
            setupWindow = window
        }
        if popoverPanel.isVisible { closePopover() }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    private func presentSettingsMenu() {
        if popoverPanel.isVisible { closePopover() }
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = manager.isOn ? "bolt.circle.fill" : "bolt.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Stay Awake")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let durationItem = NSMenuItem(title: "Lid-Closed Duration", action: nil, keyEquivalent: "")
        let durationSubmenu = NSMenu()
        for minutes in Config.durationOptions {
            let item = NSMenuItem(title: durationLabel(minutes), action: #selector(selectDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            item.state = (manager.clamshellMinutes == minutes) ? .on : .off
            durationSubmenu.addItem(item)
        }
        durationItem.submenu = durationSubmenu
        menu.addItem(durationItem)

        let autoEnableItem = NSMenuItem(title: "Auto-Enable For Apps", action: nil, keyEquivalent: "")
        autoEnableItem.submenu = buildAutoEnableSubmenu()
        menu.addItem(autoEnableItem)

        menu.addItem(.separator())

        let helperTitle = manager.clamshellHelperInstalled ? "Disable Lid-Closed Mode" : "Enable Lid-Closed Mode…"
        let helperItem = NSMenuItem(title: helperTitle, action: #selector(toggleClamshellHelper), keyEquivalent: "")
        helperItem.target = self
        menu.addItem(helperItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = manager.launchAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let setupItem = NSMenuItem(title: "Show Setup Guide…", action: #selector(openSetupFlow), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Stay Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Lists the currently-watched apps (click one to stop watching it) plus an "Add App..."
    /// item that opens a file picker scoped to /Applications. Kept deliberately simple: no
    /// separate on/off setting for the feature as a whole -- an empty list just means nothing
    /// is watched, which is the same as the feature being off.
    private func buildAutoEnableSubmenu() -> NSMenu {
        let submenu = NSMenu()
        if manager.watchedApps.isEmpty {
            let emptyItem = NSMenuItem(title: "No apps added yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for app in manager.watchedApps.sorted(by: { $0.displayName < $1.displayName }) {
                let item = NSMenuItem(title: app.displayName, action: #selector(removeWatchedApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = app.bundleID
                item.state = .on
                item.toolTip = "Click to stop auto-enabling for \(app.displayName)"
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        let addItem = NSMenuItem(title: "Add App…", action: #selector(addWatchedAppViaPicker), keyEquivalent: "")
        addItem.target = self
        submenu.addItem(addItem)
        return submenu
    }

    // AGENT NOTE: The Position Tuner debug window (PositionTunerView, showPositionTuner(),
    // resizeAndRepositionPopoverIfNeeded(), and manager.popoverOffsetX/Y) is intentionally kept in
    // this file but has no UI entry point right now -- it was used once to hand-tune the
    // popover's on-screen offset (settled on offsetX: 7, offsetY: 18, baked in above as the
    // default). If the popover ever needs re-tuning, wire a menu item back up to this method:
    //   let tunerItem = NSMenuItem(title: "Adjust Popover Position… (Debug)", action: #selector(openPositionTuner), keyEquivalent: "")
    //   tunerItem.target = self
    //   menu.addItem(tunerItem)
    // (insert into buildMenu() above, before the Quit item) and remove it again afterward.
    @objc private func openPositionTuner() {
        showPositionTuner()
    }

    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        manager.setClamshellMinutes(minutes)
    }

    @objc private func toggleClamshellHelper() {
        if manager.clamshellHelperInstalled {
            manager.removeClamshellHelper { _ in }
        } else {
            manager.installClamshellHelper { _ in }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        manager.setLaunchAtLogin(!manager.launchAtLogin)
    }

    @objc private func addWatchedAppViaPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            notifyPickerFailure()
            return
        }
        let displayName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        manager.addWatchedApp(bundleID: bundleID, displayName: displayName)
    }

    private func notifyPickerFailure() {
        let alert = NSAlert()
        alert.messageText = "Couldn't Read That App"
        alert.informativeText = "That didn't look like a valid application bundle."
        alert.runModal()
    }

    @objc private func removeWatchedApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        manager.removeWatchedApp(bundleID: bundleID)
    }

    @objc private func openSetupFlow() {
        showSetupFlow()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - First-run guided setup flow

private enum SetupStep: Int, CaseIterable {
    case welcome, notifications, launchAtLogin, lidClosed, autoEnable, done
}

private enum PermissionState { case notAsked, granted, denied }
private enum HelperSetupState { case idle, working, success, failed }

struct SetupFlowView: View {
    @ObservedObject var manager: StayAwakeManager
    var onFinish: () -> Void

    @State private var step: SetupStep = .welcome
    @State private var notifState: PermissionState = .notAsked
    @State private var helperState: HelperSetupState = .idle
    @State private var autoEnableAddedName: String?

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)

            VStack(spacing: 24) {
                Spacer(minLength: 8)
                stepContent
                Spacer(minLength: 8)
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(width: 440, height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .onAppear { manager.refreshNotificationStatus() }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            SetupStepCard(
                systemImage: "bolt.circle.fill",
                tint: .yellow,
                title: "Welcome to Stay Awake",
                description: "A quick, one-time setup. A few short steps, all optional except the first: skip anything and change it later from the right-click menu."
            )
        case .notifications:
            SetupStepCard(
                systemImage: "bell.badge.fill",
                tint: .blue,
                title: "Notifications",
                description: "Stay Awake can let you know when the safety timer is about to sleep the Mac, or if something needs your attention."
            ) {
                VStack(spacing: 10) {
                    switch notifState {
                    case .notAsked:
                        Button("Enable Notifications") {
                            manager.requestNotificationPermission { granted in
                                notifState = granted ? .granted : .denied
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    case .granted:
                        Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .denied:
                        Label("Not enabled. You can turn this on later in System Settings", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        case .launchAtLogin:
            SetupStepCard(
                systemImage: "power",
                tint: .purple,
                title: "Launch at Login",
                description: "Start Stay Awake automatically when you log in, so it's always ready in the menu bar."
            ) {
                Toggle("Launch Stay Awake at login", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
            }
        case .lidClosed:
            SetupStepCard(
                systemImage: "lock.laptopcomputer",
                tint: .orange,
                title: "Lid-Closed Mode",
                description: "Optional. Keeps the Mac awake even with the lid closed, useful for long downloads or renders. Needs a one-time admin password to install a narrowly-scoped permission for the pmset sleep command only."
            ) {
                VStack(spacing: 10) {
                    switch helperState {
                    case .idle:
                        Button("Set Up Lid-Closed Mode\u{2026}") {
                            helperState = .working
                            manager.installClamshellHelper { success in
                                helperState = success ? .success : .failed
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Text("You'll be asked for your Mac password once.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .working:
                        ProgressView().controlSize(.small)
                        Text("Waiting for your password\u{2026}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .success:
                        Label("Lid-closed mode is set up", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Label("Skipped. Try again anytime from the menu", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        case .autoEnable:
            SetupStepCard(
                systemImage: "bolt.badge.automatic.fill",
                tint: .yellow,
                title: "Auto-Enable For Apps",
                description: "Optional. Pick apps that shouldn't be interrupted, like a renderer, a long build, or a screen-share tool. Stay Awake turns itself on the moment one launches and back off once it quits, no need to remember to flip the toggle."
            ) {
                VStack(spacing: 10) {
                    if manager.watchedApps.isEmpty {
                        Button("Add an App\u{2026}") {
                            addWatchedAppViaPicker()
                        }
                        .buttonStyle(.borderedProminent)
                        if let name = autoEnableAddedName {
                            Label("Added \(name)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } else {
                        ForEach(manager.watchedApps) { app in
                            Text(app.displayName)
                                .font(.callout)
                        }
                        Button("Add Another\u{2026}") {
                            addWatchedAppViaPicker()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("You can add or remove apps anytime from the right-click menu.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        case .done:
            SetupStepCard(
                systemImage: "checkmark.seal.fill",
                tint: .green,
                title: "You're All Set",
                description: "Click the bolt icon in the menu bar to turn Stay Awake on or off. Right-click it anytime for settings, including anything you skipped here."
            )
        }
    }

    private func addWatchedAppViaPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let displayName = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        manager.addWatchedApp(bundleID: bundleID, displayName: displayName)
        autoEnableAddedName = displayName
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(SetupStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.white : Color.white.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }

            HStack {
                if step != .welcome && step != .done {
                    Button {
                        goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                Spacer()
                Button(nextButtonTitle) {
                    if step == .done { finish() } else { goNext() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var nextButtonTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .notifications, .launchAtLogin: return "Continue"
        case .lidClosed: return helperState == .success ? "Continue" : "Skip for Now"
        case .autoEnable: return manager.watchedApps.isEmpty ? "Skip for Now" : "Continue"
        case .done: return "Finish"
        }
    }

    private func goNext() {
        guard let next = SetupStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let prev = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Config.hasCompletedSetupKey)
        onFinish()
    }
}

private struct SetupStepCard<Content: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let description: String
    @ViewBuilder var content: () -> Content

    init(
        systemImage: String,
        tint: Color,
        title: String,
        description: String,
        @ViewBuilder content: @escaping () -> Content = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - App entry point

@main
struct StayAwakeMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
