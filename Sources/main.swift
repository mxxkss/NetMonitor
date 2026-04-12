import Cocoa
import Darwin
import CoreWLAN
import Security
import IOKit

// MARK: - Network

struct NetworkSnapshot {
    let rx: UInt64
    let tx: UInt64
    let timestamp: TimeInterval
}

func getNetworkBytes() -> (rx: UInt64, tx: UInt64) {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
    defer { freeifaddrs(firstAddr) }

    var rx: UInt64 = 0, tx: UInt64 = 0
    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let addr = ptr {
        let name = String(cString: addr.pointee.ifa_name)
        if addr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
           let data = addr.pointee.ifa_data {
            let d = data.assumingMemoryBound(to: if_data.self)
            rx += UInt64(d.pointee.ifi_ibytes)
            tx += UInt64(d.pointee.ifi_obytes)
        }
        ptr = addr.pointee.ifa_next
    }
    return (rx, tx)
}

func getLocalIP() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "N/A" }
    defer { freeifaddrs(firstAddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let addr = ptr {
        let name = String(cString: addr.pointee.ifa_name)
        if addr.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                           &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buf)
                if ip != "127.0.0.1" { return ip }
            }
        }
        ptr = addr.pointee.ifa_next
    }
    return "N/A"
}

func formatSpeed(_ bps: Double) -> String {
    let kb = bps / 1024, mb = kb / 1024
    if mb >= 10      { return String(format: "%3.0f MB/s", mb) }
    else if mb >= 1  { return String(format: "%3.1f MB/s", mb) }
    else if kb >= 10 { return String(format: "%3.0f KB/s", kb) }
    else             { return String(format: "%3.1f KB/s", kb) }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1 { return String(format: "%.2f GB", gb) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

func countryFlag(_ code: String) -> String {
    let base: UInt32 = 127397
    return String(code.uppercased().unicodeScalars.compactMap {
        UnicodeScalar(base + $0.value)
    }.map { Character($0) })
}

// MARK: - CPU Monitor (delta-based, exelban/stats pattern)

class CPUMonitor {
    private var prevTicks = host_cpu_load_info_data_t()
    private var prevPerCore: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []

    func totalUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }

        let user   = Double(info.cpu_ticks.0 &- prevTicks.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prevTicks.cpu_ticks.1)
        let idle   = Double(info.cpu_ticks.2 &- prevTicks.cpu_ticks.2)
        let nice   = Double(info.cpu_ticks.3 &- prevTicks.cpu_ticks.3)
        prevTicks = info

        let total = user + system + idle + nice
        return total > 0 ? ((user + system) / total) * 100 : 0
    }

    func perCoreUsage() -> [Double] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard r == KERN_SUCCESS, let info = infoArray else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }

        var usages: [Double] = []
        for i in 0..<Int(cpuCount) {
            let off = Int(CPU_STATE_MAX) * i
            let cur = (user: UInt32(info[off + Int(CPU_STATE_USER)]),
                       sys: UInt32(info[off + Int(CPU_STATE_SYSTEM)]),
                       idle: UInt32(info[off + Int(CPU_STATE_IDLE)]),
                       nice: UInt32(info[off + Int(CPU_STATE_NICE)]))

            if i < prevPerCore.count {
                let prev = prevPerCore[i]
                let u = Double(cur.user &- prev.user)
                let s = Double(cur.sys &- prev.sys)
                let id = Double(cur.idle &- prev.idle)
                let n = Double(cur.nice &- prev.nice)
                let t = u + s + id + n
                usages.append(t > 0 ? ((u + s) / t) * 100 : 0)
            } else {
                usages.append(0)
            }
        }

        prevPerCore = (0..<Int(cpuCount)).map { i in
            let off = Int(CPU_STATE_MAX) * i
            return (user: UInt32(info[off + Int(CPU_STATE_USER)]),
                    sys: UInt32(info[off + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(info[off + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(info[off + Int(CPU_STATE_NICE)]))
        }
        return usages
    }
}

// MARK: - Memory

func getMemoryUsage() -> (used: Double, total: Double, pct: Double) {
    let total = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let pageSize = Double(vm_kernel_page_size)
    let r = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return (0, total, 0) }
    let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize / (1024 * 1024 * 1024)
    return (used, total, total > 0 ? (used / total) * 100 : 0)
}

// MARK: - Disk & Uptime

func getDiskUsage() -> (used: Double, total: Double) {
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
          let total = (attrs[.systemSize] as? NSNumber)?.doubleValue,
          let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue else { return (0, 0) }
    return ((total - free) / (1024 * 1024 * 1024), total / (1024 * 1024 * 1024))
}

func getUptime() -> String {
    let ti = ProcessInfo.processInfo.systemUptime
    let d = Int(ti) / 86400, h = (Int(ti) % 86400) / 3600, m = (Int(ti) % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Wi-Fi (CoreWLAN → networkProfiles → IORegistry fallback)

func getWiFiInfo() -> (ssid: String, rssi: Int)? {
    guard let iface = CWWiFiClient.shared().interface() else { return nil }
    let rssi = iface.rssiValue()
    if rssi == 0 { return nil } // not connected

    // Try 1: direct SSID (works on macOS ≤ 13)
    if let ssid = iface.ssid(), !ssid.isEmpty { return (ssid, rssi) }

    // Try 2: saved network profiles (works macOS 14+ without entitlement)
    if let profiles = iface.configuration()?.networkProfiles {
        for case let p as CWNetworkProfile in profiles {
            if let s = p.ssid, !s.isEmpty { return (s, rssi) }
        }
    }

    // Try 3: IORegistry
    if let ssid = ssidFromIORegistry() { return (ssid, rssi) }

    return ("Wi-Fi", rssi) // connected but SSID hidden
}

func ssidFromIORegistry() -> String? {
    let matchDict = IOServiceMatching("IO80211Interface") as CFDictionary
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matchDict)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    for key in ["IO80211SSID_STR", "SSID_STR"] {
        if let val = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
           let s = val as? String, !s.isEmpty, s != "<redacted>" {
            return s
        }
    }
    return nil
}

func signalBars(_ rssi: Int) -> String {
    switch rssi {
    case -50...0:     return "\u{2587}\u{2587}\u{2587}\u{2587}"
    case -60...(-51): return "\u{2587}\u{2587}\u{2587}\u{2581}"
    case -70...(-61): return "\u{2587}\u{2587}\u{2581}\u{2581}"
    default:          return "\u{2587}\u{2581}\u{2581}\u{2581}"
    }
}

// MARK: - Battery (IOKit AppleSmartBattery)

struct BatteryInfo {
    let level: Int          // 0-100
    let charging: Bool
    let cycleCount: Int
    let health: Int         // 0-100 (maxCap / designCap)
}

func getBatteryInfo() -> BatteryInfo? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    func val(_ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }
    func flag(_ key: String) -> Bool {
        (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
    }

    guard let cur = val("CurrentCapacity"), let max = val("MaxCapacity") else { return nil }
    let design = val("DesignCapacity") ?? max
    let level = max > 0 ? (cur * 100) / max : 0
    let health = design > 0 ? (max * 100) / design : 100

    return BatteryInfo(
        level: level,
        charging: flag("IsCharging"),
        cycleCount: val("CycleCount") ?? 0,
        health: health
    )
}

// MARK: - Claude Usage (Keychain + API)

let keychainService = "team.skazka.netmonitor"

func keychainSave(key: String, value: String) {
    let data = value.data(using: .utf8)!
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: keychainService,
                             kSecAttrAccount as String: key,
                             kSecValueData as String: data]
    SecItemDelete(q as CFDictionary)
    SecItemAdd(q as CFDictionary, nil)
}

func keychainLoad(key: String) -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: keychainService,
                             kSecAttrAccount as String: key,
                             kSecReturnData as String: true,
                             kSecMatchLimit as String: kSecMatchLimitOne]
    var result: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func keychainDelete(key: String) {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                             kSecAttrService as String: keychainService,
                             kSecAttrAccount as String: key]
    SecItemDelete(q as CFDictionary)
}

// MARK: - Render menu bar image

func renderStatusImage(up: String, down: String, dateStr: String, height: CGFloat) -> NSImage {
    let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let dateFont  = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    let speedAttrs: [NSAttributedString.Key: Any] = [.font: speedFont, .foregroundColor: NSColor.black]
    let dateAttrs:  [NSAttributedString.Key: Any] = [.font: dateFont,  .foregroundColor: NSColor.black]

    let upStr   = "\u{2191}\(up)"
    let downStr = "\u{2193}\(down)"

    let upSize   = (upStr as NSString).size(withAttributes: speedAttrs)
    let downSize = (downStr as NSString).size(withAttributes: speedAttrs)
    let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)

    let speedW = max(upSize.width, downSize.width)
    let gap: CGFloat = 5
    let totalW = ceil(speedW + gap + dateSize.width + 1)

    let img = NSImage(size: NSSize(width: totalW, height: height))
    img.lockFocus()

    let lineH = height / 2
    (upStr as NSString).draw(at: NSPoint(x: 0, y: lineH + 1), withAttributes: speedAttrs)
    (downStr as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: speedAttrs)

    let dtX = speedW + gap
    let dateY = (height - dateSize.height) / 2
    (dateStr as NSString).draw(at: NSPoint(x: dtX, y: dateY), withAttributes: dateAttrs)

    img.unlockFocus()
    img.isTemplate = true
    return img
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var prevSnapshot: NetworkSnapshot?
    private var barHeight: CGFloat = 22
    private let cpuMonitor = CPUMonitor()

    // Menu items
    private var cpuItem: NSMenuItem!
    private var memItem: NSMenuItem!
    private var battItem: NSMenuItem!
    private var wifiItem: NSMenuItem!
    private var flagMenuItem: NSMenuItem!
    private var ipMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!
    private var diskItem: NSMenuItem!
    private var uptimeItem: NSMenuItem!
    private var claude5hItem: NSMenuItem!
    private var claude7dItem: NSMenuItem!
    private var claudeLoginItem: NSMenuItem!
    private var currentExtIP = ""

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d MMM"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        barHeight = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        startMonitoring()
        fetchGeoIP()
        fetchClaudeUsage()
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetchGeoIP() }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.fetchClaudeUsage() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 240

        // Calendar
        let dp = NSDatePicker()
        dp.datePickerStyle = .clockAndCalendar
        dp.datePickerElements = .yearMonthDay
        dp.dateValue = Date()
        dp.isBezeled = false
        dp.drawsBackground = false
        dp.sizeToFit()
        let dpSize = dp.fittingSize
        let calBox = NSView(frame: NSRect(x: 0, y: 0, width: dpSize.width + 8, height: dpSize.height + 8))
        dp.frame = NSRect(x: 4, y: 4, width: dpSize.width, height: dpSize.height)
        calBox.addSubview(dp)
        let calItem = NSMenuItem()
        calItem.view = calBox
        menu.addItem(calItem)
        menu.addItem(NSMenuItem.separator())

        // System info — compact
        cpuItem = NSMenuItem(title: "CPU:  ...", action: nil, keyEquivalent: "")
        cpuItem.isEnabled = false
        menu.addItem(cpuItem)

        memItem = NSMenuItem(title: "RAM:  ...", action: nil, keyEquivalent: "")
        memItem.isEnabled = false
        menu.addItem(memItem)

        battItem = NSMenuItem(title: "Battery:  ...", action: nil, keyEquivalent: "")
        battItem.isEnabled = false
        menu.addItem(battItem)

        wifiItem = NSMenuItem(title: "Wi-Fi:  ...", action: nil, keyEquivalent: "")
        wifiItem.isEnabled = false
        menu.addItem(wifiItem)

        diskItem = NSMenuItem(title: "Disk:  ...", action: nil, keyEquivalent: "")
        diskItem.isEnabled = false
        menu.addItem(diskItem)

        uptimeItem = NSMenuItem(title: "Uptime:  ...", action: nil, keyEquivalent: "")
        uptimeItem.isEnabled = false
        menu.addItem(uptimeItem)

        menu.addItem(NSMenuItem.separator())

        // Network
        flagMenuItem = NSMenuItem(title: "External IP: ...", action: #selector(copyExtIP), keyEquivalent: "")
        flagMenuItem.target = self
        menu.addItem(flagMenuItem)

        ipMenuItem = NSMenuItem(title: "Local IP: ...", action: #selector(copyLocalIP), keyEquivalent: "")
        ipMenuItem.target = self
        menu.addItem(ipMenuItem)

        rxTotalItem = NSMenuItem(title: "In: ...  Out: ...", action: nil, keyEquivalent: "")
        rxTotalItem.isEnabled = false
        menu.addItem(rxTotalItem)

        menu.addItem(NSMenuItem.separator())

        // Claude Usage
        claude5hItem = NSMenuItem(title: "Claude 5h: ...", action: nil, keyEquivalent: "")
        claude5hItem.isEnabled = false
        menu.addItem(claude5hItem)

        claude7dItem = NSMenuItem(title: "Claude 7d: ...", action: nil, keyEquivalent: "")
        claude7dItem.isEnabled = false
        menu.addItem(claude7dItem)

        claudeLoginItem = NSMenuItem(title: "Claude: Set Session Key...", action: #selector(claudeLogin), keyEquivalent: "")
        claudeLoginItem.target = self
        menu.addItem(claudeLoginItem)

        menu.addItem(NSMenuItem.separator())

        let termItem = NSMenuItem(title: "Terminal", action: #selector(openTerminal), keyEquivalent: "t")
        termItem.target = self
        menu.addItem(termItem)

        let actItem = NSMenuItem(title: "Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a")
        actItem.target = self
        menu.addItem(actItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func startMonitoring() {
        let b = getNetworkBytes()
        prevSnapshot = NetworkSnapshot(rx: b.rx, tx: b.tx, timestamp: Date().timeIntervalSince1970)
        // Warm up CPU monitor (first call returns 0)
        _ = cpuMonitor.totalUsage()
        _ = cpuMonitor.perCoreUsage()

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = Date()
        let ts = now.timeIntervalSince1970
        let b = getNetworkBytes()
        let snap = NetworkSnapshot(rx: b.rx, tx: b.tx, timestamp: ts)

        var downStr = "0.0 KB/s", upStr = "0.0 KB/s"
        if let prev = prevSnapshot {
            let dt = ts - prev.timestamp
            if dt > 0 {
                downStr = formatSpeed(Double(snap.rx - prev.rx) / dt)
                upStr   = formatSpeed(Double(snap.tx - prev.tx) / dt)
                rxTotalItem.title = "In: \(formatBytes(snap.rx))  Out: \(formatBytes(snap.tx))"
            }
        }

        // Date
        var dateStr = dateFmt.string(from: now).replacingOccurrences(of: ".", with: "")
        let parts = dateStr.split(separator: " ", maxSplits: 2)
        if parts.count == 3 {
            dateStr = "\(parts[0].prefix(1).uppercased())\(parts[0].dropFirst()) \(parts[1]) \(parts[2].prefix(1).uppercased())\(parts[2].dropFirst())"
        }

        statusItem.button?.image = renderStatusImage(up: upStr, down: downStr, dateStr: dateStr, height: barHeight)

        // CPU — delta-based sparkline
        let cpu = cpuMonitor.totalUsage()
        let cores = cpuMonitor.perCoreUsage()
        let blocks: [Character] = ["\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]
        let bars = cores.map { blocks[min(Int($0 / 12.5), 7)] }
        cpuItem.title = String(format: "CPU  %3.0f%%  %@", cpu, String(bars))

        // Memory
        let mem = getMemoryUsage()
        memItem.title = String(format: "RAM  %.1f / %.0f GB  (%.0f%%)", mem.used, mem.total, mem.pct)

        // Battery
        if let batt = getBatteryInfo() {
            let chargeIcon = batt.charging ? "\u{26A1}" : ""
            battItem.title = String(format: "Bat  %d%% %@ cyc:%d hlth:%d%%", batt.level, chargeIcon, batt.cycleCount, batt.health)
            battItem.isHidden = false
        } else {
            battItem.isHidden = true // desktop Mac — no battery
        }

        // Wi-Fi
        if let wifi = getWiFiInfo() {
            wifiItem.title = "Wi-Fi  \(wifi.ssid)  \(signalBars(wifi.rssi))  \(wifi.rssi)dBm"
        } else {
            wifiItem.title = "Wi-Fi  Not connected"
        }

        // Disk & Uptime
        let disk = getDiskUsage()
        diskItem.title = String(format: "Disk  %.0f / %.0f GB", disk.used, disk.total)
        uptimeItem.title = "Up  \(getUptime())"

        ipMenuItem.title = "Local IP: \(getLocalIP())"
        prevSnapshot = snap
    }

    // MARK: - Claude Usage

    @objc private func claudeLogin() {
        let alert = NSAlert()
        alert.messageText = "Claude Session Key"
        alert.informativeText = "1. Open claude.ai in Safari, log in\n2. Safari menu → Develop → Show Web Inspector\n   (enable in Safari → Settings → Advanced first)\n3. Tab \"Storage\" → Cookies → claude.ai\n4. Copy \"sessionKey\" value (sk-ant-sid...)\n\nOrg ID will be detected automatically."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Logout")

        let keyField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        keyField.placeholderString = "sk-ant-sid01-..."
        keyField.stringValue = keychainLoad(key: "sessionKey") ?? ""
        alert.accessoryView = keyField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                keychainSave(key: "sessionKey", value: key)
                // Auto-fetch orgId then usage
                fetchOrgIdAndUsage(sessionKey: key)
            }
        } else if response == .alertThirdButtonReturn {
            keychainDelete(key: "sessionKey")
            keychainDelete(key: "orgId")
            claude5hItem.title = "Claude 5h: —"
            claude7dItem.title = "Claude 7d: —"
        }
    }

    private func fetchOrgIdAndUsage(sessionKey: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations") else { return }
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) NetMonitor/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = orgs.first,
                  let orgId = first["uuid"] as? String
            else {
                DispatchQueue.main.async { self?.claude5hItem.title = "Claude 5h: Bad key" }
                return
            }
            keychainSave(key: "orgId", value: orgId)
            self?.fetchClaudeUsage()
        }.resume()
    }

    private func fetchClaudeUsage() {
        // Try 1: Claude Code OAuth from system Keychain
        if let token = getClaudeCodeToken() {
            fetchUsageWithOAuth(token: token)
            return
        }

        // Try 2: Manual sessionKey
        guard let sessionKey = keychainLoad(key: "sessionKey"),
              let orgId = keychainLoad(key: "orgId"),
              let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")
        else {
            DispatchQueue.main.async {
                self.claude5hItem.title = "Claude 5h: —"
                self.claude7dItem.title = "Claude 7d: —"
            }
            return
        }

        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) NetMonitor/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 401 {
                DispatchQueue.main.async { self?.claude5hItem.title = "Claude 5h: Session expired" }
                return
            }
            self?.parseUsageResponse(data)
        }.resume()
    }

    private func getClaudeCodeToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let jsonData = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String
            else { return nil }
            return token
        } catch { return nil }
    }

    private func fetchUsageWithOAuth(token: String) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("NetMonitor/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            self?.parseUsageResponse(data)
        }.resume()
    }

    private func parseUsageResponse(_ data: Data?) {
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        DispatchQueue.main.async { [weak self] in
            if let fiveH = j["five_hour"] as? [String: Any],
               let u5 = fiveH["utilization"] as? Double {
                let reset = self?.parseResetTime(fiveH["resets_at"] as? String, short: true) ?? ""
                self?.claude5hItem.title = String(format: "Claude 5h: %.0f%%%@", u5, reset)
            }
            if let sevenD = j["seven_day"] as? [String: Any],
               let u7 = sevenD["utilization"] as? Double {
                let reset = self?.parseResetTime(sevenD["resets_at"] as? String, short: false) ?? ""
                self?.claude7dItem.title = String(format: "Claude 7d: %.0f%%%@", u7, reset)
            }
        }
    }

    private func parseResetTime(_ str: String?, short: Bool) -> String {
        guard let str = str else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        guard let d = fmt.date(from: str) else { return "" }
        let rf = DateFormatter()
        rf.locale = Locale(identifier: "ru_RU")
        rf.dateFormat = short ? "HH:mm" : "d MMM HH:mm"
        return "  \u{21BB}\(rf.string(from: d))"
    }

    // MARK: - GeoIP

    private func fetchGeoIP() {
        guard let url = URL(string: "https://ipapi.co/json/") else { return }
        var req = URLRequest(url: url)
        req.setValue("NetMonitor/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = j["country_code"] as? String,
                  let ip = j["ip"] as? String
            else { return }
            DispatchQueue.main.async {
                self?.currentExtIP = ip
                self?.flagMenuItem.title = "\(countryFlag(code)) External IP: \(ip)"
            }
        }.resume()
    }

    // MARK: - Actions

    @objc private func openTerminal() { NSWorkspace.shared.launchApplication("Terminal") }
    @objc private func openActivityMonitor() { NSWorkspace.shared.launchApplication("Activity Monitor") }

    @objc private func copyLocalIP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(getLocalIP(), forType: .string)
    }

    @objc private func copyExtIP() {
        guard !currentExtIP.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentExtIP, forType: .string)
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
