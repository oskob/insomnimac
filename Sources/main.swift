import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Power control

enum Power {
    static let pmset = "/usr/bin/pmset"
    static let sudoersPath = "/etc/sudoers.d/insomnimac"

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True if `pmset -a disablesleep 1` is currently in effect.
    static var isSleepDisabled: Bool {
        let out = run(pmset, ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled", parts.count > 1 { return parts[1] == "1" }
        }
        return false
    }

    /// Try passwordless sudo (works once the sudoers rule is installed).
    static func setDisableSleep(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    /// One-time setup: asks for an admin password and installs a narrow sudoers rule
    /// allowing this user to run exactly `pmset -a disablesleep 0|1` without a password.
    static func installSudoersRule() -> Bool {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("insomnimac.sudoers")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let shell = "/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' '\(sudoersPath)'"
        let script = "do shell script \"\(shell)\" with administrator privileges with prompt \"Insomnimac needs one-time permission to control lid-close sleep.\""
        return run("/usr/bin/osascript", ["-e", script]).status == 0
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var toggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var offTimer: Timer?
    private var offDate: Date?
    private var assertionID: IOPMAssertionID = 0
    private var assertionHeld = false

    private var isOn = false { didSet { refreshUI() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        let enableItem = NSMenuItem(title: "Enable", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, minutes) in [("30 minutes", 30), ("1 hour", 60), ("4 hours", 240), ("24 hours", 1440)] {
            let item = NSMenuItem(title: "Enable for \(title)", action: #selector(enableTimed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            sub.addItem(item)
        }
        enableItem.submenu = sub
        menu.addItem(enableItem)
        // Only shown while on, so there's always a way to turn it off.
        toggleItem = NSMenuItem(title: "Disable", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Insomnimac", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu

        // Sync with the actual system state (e.g. if the app was killed while on).
        isOn = Power.isSleepDisabled
        if isOn { holdAssertion(true) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Re-sync in case something else changed pmset.
        let actual = Power.isSleepDisabled
        if actual != isOn {
            isOn = actual
            holdAssertion(actual)
            if !actual { cancelTimer() }
        }
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isOn { _ = Power.setDisableSleep(false) }
        holdAssertion(false)
    }

    @objc private func toggle() {
        cancelTimer()
        setInsomnimac(!isOn)
    }

    @objc private func enableTimed(_ sender: NSMenuItem) {
        cancelTimer()
        guard setInsomnimac(true) else { return }
        let date = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
        offDate = date
        // Wall-clock check every 15s so it stays accurate even if the timer is delayed.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, let end = self.offDate, Date() >= end else { return }
            self.cancelTimer()
            self.setInsomnimac(false)
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        offTimer = t
        refreshUI()
    }

    private func cancelTimer() {
        offTimer?.invalidate()
        offTimer = nil
        offDate = nil
        refreshUI()
    }

    @discardableResult
    private func setInsomnimac(_ on: Bool) -> Bool {
        var ok = Power.setDisableSleep(on)
        if !ok {
            guard Power.installSudoersRule() else { return false } // user cancelled
            ok = Power.setDisableSleep(on)
        }
        guard ok else {
            alert("Couldn't change sleep settings", "Running `sudo pmset -a disablesleep` failed.")
            return false
        }
        holdAssertion(on)
        isOn = Power.isSleepDisabled
        return isOn == on
    }

    /// Also prevent idle sleep while lid is open (display may still sleep).
    private func holdAssertion(_ on: Bool) {
        if on, !assertionHeld {
            assertionHeld = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Insomnimac mode" as CFString, &assertionID) == kIOReturnSuccess
        } else if !on, assertionHeld {
            IOPMAssertionRelease(assertionID)
            assertionHeld = false
        }
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            alert("Couldn't update login item", error.localizedDescription)
        }
        refreshUI()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refreshUI() {
        guard let button = statusItem?.button else { return }
        let name = isOn ? "cup.and.saucer.fill" : "moon.zzz"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: isOn ? "Insomnimac on" : "Insomnimac off")
        img?.isTemplate = true
        button.image = img
        var status = isOn ? "On — stays awake with lid closed" : "Off"
        if isOn, let end = offDate {
            let fmt = DateFormatter()
            fmt.dateStyle = Calendar.current.isDateInToday(end) ? .none : .short
            fmt.timeStyle = .short
            status = "On until \(fmt.string(from: end))"
        }
        button.toolTip = "Insomnimac: \(status)"
        hintItem?.title = status
        toggleItem?.isHidden = !isOn
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
