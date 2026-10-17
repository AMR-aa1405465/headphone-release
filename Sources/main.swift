import AppKit
import CoreAudio
import AudioToolbox
import ServiceManagement

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func check(_ status: OSStatus, _ action: String) throws {
    if status != noErr { throw AudioFailure(message: "\(action) failed (Core Audio \(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording.") }
}
func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) throws -> T {
    var value = initial, size = UInt32(MemoryLayout<T>.size), addr = address(selector)
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, pointer), "Read audio property")
    }
    return value
}
func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) throws {
    var value = id, addr = address(selector)
    try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "Change audio route")
}
func current(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
    try scalar(AudioObjectID(kAudioObjectSystemObject), selector, AudioObjectID(0))
}
func objectString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var result: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size), addr = address(selector)
    let code = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    guard code == noErr else { return "Unknown" }
    return result as String
}
struct Device {
    let id: AudioObjectID
    let name: String
    let transport: UInt32
    func hasChannels(_ scope: AudioObjectPropertyScope) -> Bool {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
    var bluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}
func devices() -> [Device] {
    var addr = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { Device(id: $0, name: objectString($0, kAudioObjectPropertyName), transport: (try? scalar($0, kAudioDevicePropertyTransportType, UInt32(0))) ?? 0) }
}

// Only aggregate statistics leave this callback. Samples are never saved.
final class Meter {
    private let lock = NSLock()
    private var peak: Float = 0
    private var count = 0
    func consume(_ list: UnsafePointer<AudioBufferList>) {
        var maximum: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let values = data.assumingMemoryBound(to: Float.self)
            for i in 0..<(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                let value = abs(values[i])
                if value.isFinite { maximum = max(maximum, value) }
            }
        }
        lock.lock(); peak = max(peak, maximum); count += 1; lock.unlock()
    }
    func take() -> (Float, Int) {
        lock.lock(); defer { lock.unlock() }
        let result = (peak, count); peak = 0; count = 0; return result
    }
}
final class Capture {
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var io: AudioDeviceIOProcID?
    let meter = Meter()
    let queue = DispatchQueue(label: "HeadphoneRelease.capture", qos: .userInteractive)
    func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Headphone Release sample meter"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Create system audio tap")
        do {
            let format: AudioStreamBasicDescription = try scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw AudioFailure(message: "This prototype requires a Float32 audio tap.")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Headphone Release Meter",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create tap aggregate")
            let meter = self.meter
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, queue) { _, input, _, _, _ in meter.consume(input) }, "Create sample callback")
            try check(AudioDeviceStart(aggregate, io), "Start sample detection")
        } catch { stop(); throw error }
    }
    func stop() {
        if aggregate != 0, let io { AudioDeviceStop(aggregate, io); AudioDeviceDestroyIOProcID(aggregate, io) }
        io = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
}

// A lower hold threshold preserves quiet tails; only sustained audio wakes a released route.
struct SilenceGate {
    enum Decision { case none, acquire, release }
    var timeout: Double
    var threshold: Float
    var attack: Double
    var lastSound: Double
    var candidate: Double?
    var released = false
    mutating func update(peak: Float, now: Double, hasSamples: Bool, always: Bool) -> Decision {
        guard hasSamples else { candidate = nil; return .none }
        if always {
            lastSound = now; candidate = nil
            if released { released = false; return .acquire }
            return .none
        }
        if released {
            if peak >= threshold {
                if candidate == nil { candidate = now }
                if now - candidate! >= attack {
                    released = false; lastSound = now; candidate = nil; return .acquire
                }
            } else { candidate = nil }
        } else {
            if peak >= threshold * 0.316228 { lastSound = now }
            if now - lastSound >= timeout { released = true; candidate = nil; return .release }
        }
        return .none
    }
}
struct DeviceChoice {
    let uid: String?
    let title: String
}
func deviceChoices(_ available: [(uid: String, name: String)], savedUID: String, savedName: String?) -> [DeviceChoice] {
    var choices = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map { DeviceChoice(uid: $0.uid, title: $0.name) }
    if !savedUID.isEmpty && !available.contains(where: { $0.uid == savedUID }) {
        choices.append(DeviceChoice(uid: savedUID, title: "\(savedName ?? "Saved device") (disconnected)"))
    }
    if choices.isEmpty { choices = [DeviceChoice(uid: nil, title: "No connected devices")] }
    return choices
}
struct Preferences: Codable {
    var headphonesUID = ""
    var fallbackUID = ""
    var headphonesName: String?
    var fallbackName: String?
    var silence: Double = 5
    var threshold: Float = -60
    var attack: Double = 0.1
    var builtInMic = false
    var always = false
}
struct RouteRecord: Codable {
    let selector: UInt32
    let originalUID: String
    var expectedUID: String
}
extension Device { var uid: String { objectString(id, kAudioDevicePropertyDeviceUID) } }
final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let defaults = UserDefaults.standard
    var prefs = Preferences()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let menuState = NSMenuItem(title: "Stopped", action: nil, keyEquivalent: "")
    let menuToggle = NSMenuItem(title: "Start", action: #selector(toggleAction), keyEquivalent: "")
    let menuAlways = NSMenuItem(title: "Always use headphones", action: #selector(alwaysAction), keyEquivalent: "")
    let headphones = NSPopUpButton(), fallback = NSPopUpButton()
    let silence = NSTextField(string: "5"), threshold = NSTextField(string: "-60"), attack = NSTextField(string: "0.1")
    let mic = NSButton(checkboxWithTitle: "Use built-in microphone while enabled", target: nil, action: nil)
    let always = NSButton(checkboxWithTitle: "Always use headphones (disable silence release)", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "Start at login", target: nil, action: nil)
    let loginStatus = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Stopped")
    let level = NSTextField(labelWithString: "Audio level: —")
    let toggle = NSButton(title: "Start", target: nil, action: nil)
    var capture: Capture?, sampleTimer: Timer?, recoveryTimer: Timer?
    let audioLifecycle = DispatchQueue(label: "HeadphoneRelease.lifecycle")
    var setupToken = UUID()
    var setupPending = false
    var setupTimeout: Timer?
    var outputs: [Device] = []
    var journal: [RouteRecord] = []
    var enabled = false, sleeping = false
    var target: AudioObjectID = 0, parked: AudioObjectID = 0
    var gate = SilenceGate(timeout: 5, threshold: 0.001, attack: 0.1, lastSound: 0)
    var lastCallback: Double = 0, nextRecovery: Double = 0
    var retries = 0
    var availableSince: Double?
    var lastDeviceScan: Double = 0
    let outputSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
    var now: Double { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = defaults.data(forKey: "preferences"), let value = try? JSONDecoder().decode(Preferences.self, from: data) { prefs = value }
        if let data = defaults.data(forKey: "routeJournal"), let value = try? JSONDecoder().decode([RouteRecord].self, from: data) { journal = value }
        let recoveryMessage = restoreRoutes()
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu(); let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Headphone Release", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu; mainMenu.addItem(appItem); NSApp.mainMenu = mainMenu
        let menu = NSMenu(); menu.addItem(menuState); menu.addItem(.separator())
        menu.addItem(withTitle: "Show settings", action: #selector(show), keyEquivalent: "").target = self
        menuToggle.target = self; menu.addItem(menuToggle)
        menuAlways.target = self; menu.addItem(menuAlways)
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit and restore routes", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); statusItem.menu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 710), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Headphone Release"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Release Bluetooth headphones during silence and reclaim them when audio returns. The beginning of resumed audio may play through fallback speakers."))
        for (label, control) in [("Bluetooth headphones", headphones), ("Fallback output", fallback)] {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            if control === headphones {
                let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshDevices))
                stack.addArrangedSubview(NSStackView(views: [control, refresh]))
                let bluetooth = NSButton(title: "Bluetooth Settings…", target: self, action: #selector(openBluetoothSettings))
                stack.addArrangedSubview(bluetooth)
                stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Only connected audio devices appear here. Connect or pair headphones in Bluetooth Settings, then refresh."))
            } else { stack.addArrangedSubview(control) }
            control.target = self; control.action = #selector(deviceChanged)
        }
        silence.stringValue = String(prefs.silence); threshold.stringValue = String(prefs.threshold); attack.stringValue = String(prefs.attack)
        let settings = NSStackView(views: [NSTextField(labelWithString: "Silence (s):"), silence, NSTextField(labelWithString: "Threshold (dBFS):"), threshold])
        for field in [silence, threshold, attack] { field.widthAnchor.constraint(equalToConstant: 65).isActive = true; field.delegate = self }
        stack.addArrangedSubview(settings)
        stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Audio must persist before reclaiming (s):"), attack]))
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Use 0 for immediate switching, or 0.2–0.3 to ignore many brief sounds. Quiet tails receive a 10 dB allowance."))
        mic.state = prefs.builtInMic ? .on : .off; mic.target = self; mic.action = #selector(settingsChanged)
        always.state = prefs.always ? .on : .off; always.target = self; always.action = #selector(alwaysAction)
        stack.addArrangedSubview(mic); stack.addArrangedSubview(always)
        login.target = self; login.action = #selector(loginAction)
        stack.addArrangedSubview(login); stack.addArrangedSubview(loginStatus)
        stack.addArrangedSubview(level); stack.addArrangedSubview(status)
        refreshLoginStatus()
        toggle.target = self; toggle.action = #selector(toggleAction)
        stack.addArrangedSubview(toggle)
        refreshDevices(); updateControls(); report("Stopped", recoveryMessage.isEmpty ? "Settings are saved automatically. Click Start to enable." : recoveryMessage)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recoverTick() }
        window.center()
        if CommandLine.arguments.contains("--show-settings") || defaults.data(forKey: "preferences") == nil { show() }
        if defaults.bool(forKey: "startOnLaunch") { toggleAction() }
    }
    @objc func show() { reloadDevices(); refreshLoginStatus(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { if window != nil { refreshLoginStatus() } }
    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on; loginStatus.stringValue = "Enabled. Runs in the menu bar at login; resumes if last left running."
        case .requiresApproval: login.state = .mixed; loginStatus.stringValue = "Approval needed in System Settings → General → Login Items."
        case .notRegistered: login.state = .off; loginStatus.stringValue = "Off. Closing settings keeps the app in the menu bar."
        case .notFound: login.state = .off; loginStatus.stringValue = "Move the app to Applications before enabling login startup."
        @unknown default: login.state = .off; loginStatus.stringValue = "Login item status unavailable."
        }
    }
    @objc func loginAction() {
        do {
            if login.state == .on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus(); loginStatus.stringValue = "Login startup could not be changed: \(error.localizedDescription)"
        }
    }
    func persist() { if let data = try? JSONEncoder().encode(prefs) { defaults.set(data, forKey: "preferences") } }
    func saveJournal() {
        if journal.isEmpty { defaults.removeObject(forKey: "routeJournal") }
        else if let data = try? JSONEncoder().encode(journal) { defaults.set(data, forKey: "routeJournal") }
        // Flush before routing so a subsequent launch can recover after an abnormal exit.
        defaults.synchronize()
    }
    func readSettings() throws {
        guard let seconds = Double(silence.stringValue), seconds.isFinite, (1...120).contains(seconds),
              let db = Float(threshold.stringValue), db.isFinite, (-100 ... -10).contains(db),
              let delay = Double(attack.stringValue), delay.isFinite, (0...2).contains(delay) else {
            throw AudioFailure(message: "Use silence 1–120 s, threshold −100 to −10 dBFS, and reclaim delay 0–2 s.")
        }
        prefs.silence = seconds; prefs.threshold = db; prefs.attack = delay; prefs.builtInMic = mic.state == .on
        if let uid = headphones.selectedItem?.representedObject as? String { prefs.headphonesUID = uid }
        if let uid = fallback.selectedItem?.representedObject as? String { prefs.fallbackUID = uid }
        if let device = outputs.first(where: { $0.uid == prefs.headphonesUID }) { prefs.headphonesName = device.name }
        if let device = outputs.first(where: { $0.uid == prefs.fallbackUID }) { prefs.fallbackName = device.name }
        persist()
    }
    @objc func settingsChanged() { do { try readSettings() } catch { report("Settings", error.localizedDescription) } }
    func controlTextDidEndEditing(_ obj: Notification) { settingsChanged() }
    @objc func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
    @objc func deviceChanged() {
        let resume = enabled
        endSession()
        // An explicit device change starts a new restoration baseline.
        journal.removeAll(); saveJournal()
        do {
            try readSettings(); retries = 0; availableSince = nil; nextRecovery = now
            if resume { report("Waiting", "Device selection updated. Monitoring will resume when both outputs are connected.") }
            else { report("Stopped", "Device selection saved. Click Start to enable.") }
        } catch { stop(); report("Settings", error.localizedDescription) }
        updateControls()
    }
    @objc func refreshDevices() {
        reloadDevices(force: true)
        if capture == nil && !setupPending {
            let found = outputs.filter { $0.bluetooth }.count
            if found == 0 { report(enabled ? "Waiting" : "Stopped", "No connected Bluetooth audio devices. Connect your headphones in Bluetooth Settings, then refresh.") }
            else { report(enabled ? "Waiting" : "Stopped", "Found \(found) Bluetooth audio device(s). Choose your headphones above.") }
        }
    }
    func reloadDevices(force: Bool = false) {
        let latest = devices().filter { $0.hasChannels(kAudioObjectPropertyScopeOutput) }
        let fingerprint: ([Device]) -> [String] = { $0.map { "\($0.id):\($0.uid):\($0.name)" }.sorted() }
        guard force || fingerprint(latest) != fingerprint(outputs) else { return }
        outputs = latest
        for (control, uid, name, isHeadphone) in [(headphones, prefs.headphonesUID, prefs.headphonesName, true), (fallback, prefs.fallbackUID, prefs.fallbackName, false)] {
            control.removeAllItems()
            let available = outputs.filter { $0.bluetooth == isHeadphone }.map { (uid: $0.uid, name: $0.name) }
            for choice in deviceChoices(available, savedUID: uid, savedName: name) {
                control.addItem(withTitle: choice.title); control.lastItem?.representedObject = choice.uid
            }
            if let index = control.itemArray.firstIndex(where: { ($0.representedObject as? String) == uid }) { control.selectItem(at: index) }
            else if !isHeadphone, uid.isEmpty, let builtIn = outputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }), let index = control.itemArray.firstIndex(where: { ($0.representedObject as? String) == builtIn.uid }) { control.selectItem(at: index) }
        }
    }
    func updateControls() {
        headphones.isEnabled = true; fallback.isEnabled = true
        for control in [silence as NSControl, threshold, attack, mic] { control.isEnabled = !enabled }
        toggle.title = enabled ? "Stop and restore" : "Start"; menuToggle.title = enabled ? "Stop and restore" : "Start"
        always.state = prefs.always ? .on : .off; menuAlways.state = always.state
    }
    func report(_ state: String, _ detail: String) {
        status.stringValue = detail; menuState.title = state
        statusItem?.button?.title = "🎧 \(state)"
        statusItem?.button?.toolTip = detail
    }
    @objc func toggleAction() {
        if enabled { stop(); return }
        do {
            try readSettings()
            guard !prefs.headphonesUID.isEmpty, !prefs.fallbackUID.isEmpty else { throw AudioFailure(message: "Connect headphones and select both outputs.") }
            enabled = true; defaults.set(true, forKey: "startOnLaunch"); retries = 0; updateControls()
            if selectedDevices() != nil { try startSession() }
            else { report("Waiting", "Waiting for your saved headphones and fallback output to reconnect.") }
        } catch { stop(); report("Stopped", error.localizedDescription) }
    }
    func selectedDevices() -> (Device, Device)? {
        let all = devices()
        guard let headphone = all.first(where: { $0.uid == prefs.headphonesUID && $0.bluetooth && $0.hasChannels(kAudioObjectPropertyScopeOutput) }),
              let other = all.first(where: { $0.uid == prefs.fallbackUID && !$0.bluetooth && $0.hasChannels(kAudioObjectPropertyScopeOutput) }) else { return nil }
        return (headphone, other)
    }
    func startSession() throws {
        guard !setupPending else { throw AudioFailure(message: "Audio setup is still waiting on macOS. Quit and reopen if it does not finish.") }
        guard let (headphone, other) = selectedDevices() else { throw AudioFailure(message: "Selected devices are unavailable.") }
        guard journal.isEmpty else { throw AudioFailure(message: "An earlier route could not be restored. Reconnect that device or set your audio routes manually, then restart the app.") }
        target = headphone.id; parked = other.id
        let token = UUID(); setupToken = token; setupPending = true
        report("Starting", "Starting audio capture. Approve the macOS audio recording prompt if shown.")
        setupTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.setupPending, self.setupToken == token else { return }
            self.stop()
            self.report("Stopped", "macOS audio setup timed out. Check audio recording permission; quit and reopen if setup remains blocked.")
        }
        // Some Core Audio calls can block on permissions or the audio server. Keep the UI responsive.
        audioLifecycle.async { [weak self] in
            let session = Capture()
            let result: Result<Void, Error>
            do { try session.start(); result = .success(()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { session.stop(); return }
                self.setupPending = false
                guard self.setupToken == token, self.enabled, !self.sleeping else {
                    self.audioLifecycle.async { session.stop() }; return
                }
                self.setupTimeout?.invalidate(); self.setupTimeout = nil
                do {
                    try result.get()
                    guard let (currentHeadphone, currentFallback) = self.selectedDevices(), currentHeadphone.id == self.target, currentFallback.id == self.parked else {
                        self.audioLifecycle.async { session.stop() }
                        self.suspend("Devices changed during setup. Waiting to reconnect."); return
                    }
                    self.capture = session
                    if self.prefs.builtInMic {
                        guard let input = devices().first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.hasChannels(kAudioObjectPropertyScopeInput) }) else { throw AudioFailure(message: "No built-in microphone is available.") }
                        try self.change(kAudioHardwarePropertyDefaultInputDevice, input.id)
                    }
                    try self.route(self.target)
                    self.gate = SilenceGate(timeout: self.prefs.silence, threshold: pow(10, self.prefs.threshold / 20), attack: self.prefs.attack, lastSound: self.now)
                    self.lastCallback = self.now; self.lastDeviceScan = self.now
                    self.sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
                    self.report(self.prefs.always ? "Always on" : "Playing", self.prefs.always ? "Headphones held active until you disable Always use headphones." : "Monitoring audio. Waiting for sustained silence.")
                } catch {
                    self.audioLifecycle.async { session.stop() }
                    self.stop(); self.report("Stopped", error.localizedDescription)
                }
            }
        }
    }
    func change(_ selector: AudioObjectPropertySelector, _ id: AudioObjectID) throws {
        let previousJournal = journal
        let uid = objectString(id, kAudioDevicePropertyDeviceUID)
        if let i = journal.firstIndex(where: { $0.selector == selector }) { journal[i].expectedUID = uid }
        else { journal.append(RouteRecord(selector: selector, originalUID: objectString(try current(selector), kAudioDevicePropertyDeviceUID), expectedUID: uid)) }
        saveJournal()
        do { try setDefault(selector, id) }
        catch { journal = previousJournal; saveJournal(); throw error }
    }
    func route(_ id: AudioObjectID) throws { for selector in outputSelectors { try change(selector, id) } }
    @discardableResult func restoreRoutes() -> String {
        let all = devices(); var pending: [RouteRecord] = []
        for entry in journal {
            guard let active = try? current(entry.selector) else { pending.append(entry); continue }
            // Never replace an audio route changed by the user, another app, or macOS.
            guard objectString(active, kAudioDevicePropertyDeviceUID) == entry.expectedUID else { continue }
            guard let original = all.first(where: { $0.uid == entry.originalUID }) else { pending.append(entry); continue }
            do { try setDefault(entry.selector, original.id) } catch { pending.append(entry) }
        }
        let hadEntries = !journal.isEmpty; journal = pending; saveJournal()
        if !pending.isEmpty { return "Some previous routes could not be restored. Reconnect the original device, or choose your routes manually and restart." }
        return hadEntries ? "Previous routes restored where still controlled by this app." : ""
    }
    func endSession() {
        setupToken = UUID(); setupTimeout?.invalidate(); setupTimeout = nil
        sampleTimer?.invalidate(); sampleTimer = nil
        if let session = capture { capture = nil; audioLifecycle.async { session.stop() } }
        _ = restoreRoutes(); level.stringValue = "Audio level: —"
    }
    func stop() {
        enabled = false; defaults.set(false, forKey: "startOnLaunch"); availableSince = nil; endSession(); updateControls()
        report("Stopped", journal.isEmpty ? "Stopped. Previous routes restored where still controlled by this app." : "Stopped. Some routes await restoration; reconnect the original device or set routes manually.")
    }
    func suspend(_ reason: String) {
        endSession(); availableSince = nil; nextRecovery = now + 2; report("Waiting", reason)
    }
    @objc func alwaysAction() {
        prefs.always.toggle(); persist(); updateControls()
        guard capture != nil else { return }
        do {
            if prefs.always { try route(target); gate.released = false }
            gate.lastSound = now; gate.candidate = nil
            report(prefs.always ? "Always on" : "Playing", prefs.always ? "Headphones held active. Silence release is disabled." : "Automatic silence release enabled.")
        } catch { stop(); report("Stopped", error.localizedDescription) }
    }
    func tick() {
        guard let capture else { return }
        do {
            if now - lastDeviceScan >= 1 {
                lastDeviceScan = now
                guard selectedDevices() != nil else { suspend("Headphones or fallback disconnected. Will resume after reconnecting."); return }
            }
            for entry in journal {
                let active = try current(entry.selector)
                if objectString(active, kAudioDevicePropertyDeviceUID) != entry.expectedUID {
                    // A disconnect can change the route before the next regular device scan.
                    if selectedDevices() == nil { suspend("Device disconnected. Waiting to reconnect.") }
                    else { stop(); report("Paused", "An audio route changed outside the app. Click Start to resume.") }
                    return
                }
            }
            let (peak, callbacks) = capture.meter.take(), time = now
            if callbacks > 0 { lastCallback = time }
            level.stringValue = String(format: "Audio peak: %.1f dBFS%@", 20 * log10(max(peak, 0.0000001)), callbacks == 0 ? " (waiting for samples)" : "")
            if time - lastCallback > 4 {
                retries += 1
                if retries > 3 { stop(); report("Stopped", "Capture failed repeatedly. Check system audio recording permission, then click Start.") }
                else { suspend("Audio capture stalled. Retrying (\(retries)/3)…") }
                return
            }
            switch gate.update(peak: peak, now: time, hasSamples: callbacks > 0, always: prefs.always) {
            case .acquire: try route(target); report("Playing", "Audio detected → headphones")
            case .release: try route(parked); report("Released", "Silent → fallback output. Headphones available to the other device.")
            case .none: break
            }
        } catch { stop(); report("Stopped", error.localizedDescription) }
    }
    func recoverTick() {
        reloadDevices()
        guard enabled, !sleeping, !setupPending, capture == nil, now >= nextRecovery else { return }
        guard selectedDevices() != nil else { availableSince = nil; return }
        if availableSince == nil { availableSince = now; return }
        guard now - availableSince! >= 2 else { return }
        _ = restoreRoutes()
        do { try startSession(); availableSince = nil }
        catch {
            retries += 1; availableSince = nil; nextRecovery = now + 3
            if retries > 3 { stop(); report("Stopped", error.localizedDescription) }
            else { report("Waiting", "Retrying audio setup (\(retries)/3): \(error.localizedDescription)") }
        }
    }
    @objc func willSleep() { sleeping = true; if enabled { suspend("Mac sleeping. Will resume after wake.") } }
    @objc func didWake() { sleeping = false; availableSince = nil; nextRecovery = now + 2 }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { enabled = false; endSession(); recoveryTimer?.invalidate(); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
if CommandLine.arguments.contains("--self-test") {
    let meter = Meter()
    func feed(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { values in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: UnsafeMutableRawPointer(mutating: values.baseAddress)))
            withUnsafePointer(to: &list) { meter.consume($0) }
        }
    }
    feed([0, 0, 0]); let silent = meter.take()
    precondition(silent.0 == 0 && silent.1 == 1, "Silent samples")
    feed([-0.25, 0.125]); feed([0.5, .nan, .infinity])
    let signal = meter.take()
    precondition(signal.0 == 0.5 && signal.1 == 2, "Peak across callbacks and non-finite handling")
    let reset = meter.take()
    precondition(reset.0 == 0 && reset.1 == 0, "No callbacks distinguishable from silence")
    precondition(abs(20 * log10(signal.0) + 6.0206) < 0.001, "dBFS conversion")
    var gate = SilenceGate(timeout: 5, threshold: 0.001, attack: 0.2, lastSound: 0)
    precondition(gate.update(peak: 0, now: 5, hasSamples: false, always: false) == .none && !gate.released, "Missing samples never release")
    precondition(gate.update(peak: 0, now: 4.9, hasSamples: true, always: false) == .none, "Keep route during pause")
    precondition(gate.update(peak: 0, now: 5, hasSamples: true, always: false) == .release, "Release at timeout")
    precondition(gate.update(peak: 0.2, now: 6, hasSamples: true, always: false) == .none, "Brief sound does not reclaim")
    precondition(gate.update(peak: 0, now: 6.1, hasSamples: true, always: false) == .none, "Silence cancels attack")
    precondition(gate.update(peak: 0.2, now: 7, hasSamples: true, always: false) == .none, "Begin sustained sound")
    precondition(gate.update(peak: 0.2, now: 7.21, hasSamples: true, always: false) == .acquire, "Sustained sound reclaims")
    precondition(gate.update(peak: 0.0004, now: 11, hasSamples: true, always: false) == .none, "Quiet tails hold route")
    precondition(gate.update(peak: 0, now: 15, hasSamples: true, always: false) == .none, "Quiet tail reset silence timer")
    precondition(gate.update(peak: 0, now: 16, hasSamples: true, always: false) == .release, "Release after tail")
    precondition(gate.update(peak: 0, now: 17, hasSamples: true, always: true) == .acquire, "Always mode reclaims")
    precondition(gate.update(peak: 0, now: 100, hasSamples: true, always: true) == .none && !gate.released, "Always mode holds silence")
    gate = SilenceGate(timeout: 5, threshold: 0.001, attack: 0, lastSound: 0, released: true)
    precondition(gate.update(peak: 0.1, now: 1, hasSamples: true, always: false) == .acquire, "Zero attack is immediate")
    var settings = Preferences(); settings.headphonesUID = "stable-headset-uid"; settings.attack = 0.3; settings.always = true
    let saved = try! JSONEncoder().encode(settings)
    let loaded = try! JSONDecoder().decode(Preferences.self, from: saved)
    precondition(loaded.headphonesUID == settings.headphonesUID && loaded.attack == 0.3 && loaded.always, "Preference round trip")
    let journal = [RouteRecord(selector: 123, originalUID: "original", expectedUID: "owned")]
    let restored = try! JSONDecoder().decode([RouteRecord].self, from: JSONEncoder().encode(journal))
    precondition(restored[0].originalUID == "original" && restored[0].expectedUID == "owned", "Crash journal round trip")
    let connected = deviceChoices([(uid: "b", name: "Bose"), (uid: "s", name: "Sony")], savedUID: "old", savedName: "Old headset")
    precondition(connected.count == 3 && connected[0].uid == "b" && connected[2].title == "Old headset (disconnected)", "Connected alternatives remain visible beside saved missing device")
    let reconnected = deviceChoices([(uid: "old", name: "Old headset")], savedUID: "old", savedName: nil)
    precondition(reconnected.count == 1 && reconnected[0].title == "Old headset", "Reconnect replaces disconnected placeholder")
    precondition(deviceChoices([], savedUID: "", savedName: nil)[0].uid == nil, "Empty picker has no selectable fake device UID")
    print("PASS: device picker reconnect/alternatives, sample meter, silence timeout, missing samples, brief sounds, sustained audio, quiet tails, always mode, immediate attack, saved preferences, crash journal")
    exit(0)
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
