import Cocoa
import Darwin
import CoreWLAN
import Security
import IOKit

// MARK: - Logger

final class Log {
    static let shared = Log()
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "netmonitor.log", qos: .utility)
    let path: String

    private init() {
        let dir = NSHomeDirectory() + "/Library/Logs/NetMonitor"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        path = dir + "/netmonitor.log"

        // Rotate if > 1MB
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 1_000_000 {
            let old = dir + "/netmonitor.old.log"
            try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.moveItem(atPath: path, toPath: old)
        }

        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    func write(_ msg: String, level: String = "INFO") {
        queue.async { [weak self] in
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] [\(level)] \(msg)\n"
            if let data = line.data(using: .utf8) {
                self?.handle?.write(data)
            }
        }
    }

    func info(_ msg: String) { write(msg, level: "INFO") }
    func warn(_ msg: String) { write(msg, level: "WARN") }
    func error(_ msg: String) { write(msg, level: "ERROR") }
    func fatal(_ msg: String) { write(msg, level: "FATAL") }
}

// MARK: - Crash Handlers

private func writeCrashLog(_ msg: String) {
    // Async-signal-safe: open/write/close only
    let path = NSHomeDirectory() + "/Library/Logs/NetMonitor/crash.log"
    guard let cPath = path.cString(using: .utf8) else { return }
    let fd = Darwin.open(cPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    msg.utf8CString.withUnsafeBufferPointer { buf in
        _ = Darwin.write(fd, buf.baseAddress, buf.count - 1) // exclude null terminator
    }
    _ = Darwin.write(fd, "\n", 1)
    Darwin.close(fd)
}

func installCrashHandlers() {
    NSSetUncaughtExceptionHandler { exception in
        let msg = "[FATAL] Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "no reason")\nStack: \(exception.callStackSymbols.joined(separator: "\n"))"
        Log.shared.fatal(msg)
        writeCrashLog(msg)
    }

    for sig: Int32 in [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
        signal(sig) { s in
            writeCrashLog("[FATAL] Signal \(s) received")
            signal(s, SIG_DFL)
            raise(s)
        }
    }
}

func getAppMemoryMB() -> String {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard r == KERN_SUCCESS else { return "?" }
    return String(format: "%.1f", Double(info.resident_size) / (1024 * 1024))
}

// MARK: - Calendar View

class CalendarView: NSView {
    private var displayedMonth: Date
    private let cellSize: CGFloat = 36
    private let headerHeight: CGFloat = 32
    private let weekdayHeaderHeight: CGFloat = 24
    private let padding: CGFloat = 8
    private let cols = 7

    private var prevButton: NSButton!
    private var nextButton: NSButton!

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 268, height: 280)
    }

    init() {
        self.displayedMonth = Date()
        let size = NSSize(width: 268, height: 280)
        super.init(frame: NSRect(origin: .zero, size: size))

        prevButton = makeNavButton(title: "\u{25C0}", action: #selector(prevMonth))
        nextButton = makeNavButton(title: "\u{25B6}", action: #selector(nextMonth))
        addSubview(prevButton)
        addSubview(nextButton)
        layoutNavButtons()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeNavButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.font = NSFont.systemFont(ofSize: 13)
        b.sizeToFit()
        return b
    }

    private func layoutNavButtons() {
        let w = frame.width
        prevButton.frame.origin = NSPoint(x: w - 60, y: frame.height - padding - headerHeight + 4)
        nextButton.frame.origin = NSPoint(x: w - 32, y: frame.height - padding - headerHeight + 4)
    }

    @objc private func prevMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        needsDisplay = true
    }

    @objc private func nextMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let cal = Calendar(identifier: .gregorian)
        let today = Date()

        // Month/year header
        let comps = cal.dateComponents([.year, .month], from: displayedMonth)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = "LLLL yyyy"
        let title = fmt.string(from: displayedMonth).prefix(1).uppercased() + fmt.string(from: displayedMonth).dropFirst()
        let titleFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: NSColor.labelColor]
        let titleY = bounds.height - padding - headerHeight + 6
        (title as NSString).draw(at: NSPoint(x: padding, y: titleY), withAttributes: titleAttrs)

        // Weekday headers
        let weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        let wdFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let wdAttrs: [NSAttributedString.Key: Any] = [.font: wdFont, .foregroundColor: NSColor.secondaryLabelColor]
        let wdY = bounds.height - padding - headerHeight - weekdayHeaderHeight + 4
        for (i, wd) in weekdays.enumerated() {
            let x = padding + CGFloat(i) * cellSize
            let size = (wd as NSString).size(withAttributes: wdAttrs)
            let centeredX = x + (cellSize - size.width) / 2
            (wd as NSString).draw(at: NSPoint(x: centeredX, y: wdY), withAttributes: wdAttrs)
        }

        // Calculate first day of month
        var firstOfMonth = DateComponents()
        firstOfMonth.year = comps.year
        firstOfMonth.month = comps.month
        firstOfMonth.day = 1
        guard let firstDate = cal.date(from: firstOfMonth) else { return }
        var weekday = cal.component(.weekday, from: firstDate) - 2 // Monday = 0
        if weekday < 0 { weekday += 7 }
        let daysInMonth = cal.range(of: .day, in: .month, for: firstDate)?.count ?? 30

        let dayFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        let gridTop = bounds.height - padding - headerHeight - weekdayHeaderHeight

        // Previous month trailing days
        guard let prevMonthDate = cal.date(byAdding: .month, value: -1, to: firstDate) else { return }
        let prevMonthDays = cal.range(of: .day, in: .month, for: prevMonthDate)?.count ?? 30
        let dimAttrs: [NSAttributedString.Key: Any] = [.font: dayFont, .foregroundColor: NSColor.tertiaryLabelColor]
        for i in 0..<weekday {
            let day = prevMonthDays - weekday + 1 + i
            let col = i
            let row = 0
            let x = padding + CGFloat(col) * cellSize
            let y = gridTop - CGFloat(row + 1) * cellSize
            drawDay("\(day)", in: NSRect(x: x, y: y, width: cellSize, height: cellSize), attrs: dimAttrs, isToday: false)
        }

        // Current month days
        let todayComps = cal.dateComponents([.year, .month, .day], from: today)
        for day in 1...daysInMonth {
            let pos = weekday + day - 1
            let col = pos % 7
            let row = pos / 7
            let x = padding + CGFloat(col) * cellSize
            let y = gridTop - CGFloat(row + 1) * cellSize

            let isToday = todayComps.year == comps.year && todayComps.month == comps.month && todayComps.day == day
            let isWeekend = col >= 5
            let color: NSColor = isToday ? .white : isWeekend ? .systemOrange : .labelColor
            let attrs: [NSAttributedString.Key: Any] = [.font: dayFont, .foregroundColor: color]
            drawDay("\(day)", in: NSRect(x: x, y: y, width: cellSize, height: cellSize), attrs: attrs, isToday: isToday)
        }

        // Next month leading days
        let totalCells = weekday + daysInMonth
        let remaining = (7 - totalCells % 7) % 7
        for i in 0..<remaining {
            let pos = totalCells + i
            let col = pos % 7
            let row = pos / 7
            let x = padding + CGFloat(col) * cellSize
            let y = gridTop - CGFloat(row + 1) * cellSize
            drawDay("\(i + 1)", in: NSRect(x: x, y: y, width: cellSize, height: cellSize), attrs: dimAttrs, isToday: false)
        }
    }

    private func drawDay(_ text: String, in rect: NSRect, attrs: [NSAttributedString.Key: Any], isToday: Bool) {
        if isToday {
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            NSColor.systemBlue.setFill()
            circle.fill()
        }
        let size = (text as NSString).size(withAttributes: attrs)
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
}

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
    guard let data = value.data(using: .utf8) else {
        Log.shared.error("keychainSave: failed to encode value for key '\(key)'")
        return
    }
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

    let textColor: NSColor = {
        if let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
           appearance == .darkAqua {
            return .white
        }
        return .black
    }()
    let speedAttrs: [NSAttributedString.Key: Any] = [.font: speedFont, .foregroundColor: textColor]
    let dateAttrs:  [NSAttributedString.Key: Any] = [.font: dateFont,  .foregroundColor: textColor]

    let upStr   = "\u{2191}\(up)"
    let downStr = "\u{2193}\(down)"

    let upSize   = (upStr as NSString).size(withAttributes: speedAttrs)
    let downSize = (downStr as NSString).size(withAttributes: speedAttrs)
    let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)

    let speedW = max(upSize.width, downSize.width)
    let gap: CGFloat = 5
    let totalW = ceil(speedW + gap + dateSize.width + 1)
    let size = NSSize(width: totalW, height: height)

    let img = NSImage(size: size, flipped: false) { _ in
        let lineH = height / 2
        (upStr as NSString).draw(at: NSPoint(x: 0, y: lineH + 1), withAttributes: speedAttrs)
        (downStr as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: speedAttrs)

        let dtX = speedW + gap
        let dateY = (height - dateSize.height) / 2
        (dateStr as NSString).draw(at: NSPoint(x: dtX, y: dateY), withAttributes: dateAttrs)
        return true
    }
    img.isTemplate = false
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
        Log.shared.info("=== NetMonitor starting (pid: \(ProcessInfo.processInfo.processIdentifier)) ===")
        NSApp.setActivationPolicy(.accessory)
        barHeight = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        startMonitoring()
        fetchGeoIP()
        fetchClaudeUsage()
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchGeoIP()
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.fetchClaudeUsage() }
        // Monitor sleep/wake — common crash trigger
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Log.shared.info("System going to sleep")
        }
        wsnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.shared.info("System woke up — resetting network snapshot")
            // Reset snapshot to avoid UInt64 delta issues after sleep
            let b = getNetworkBytes()
            self?.prevSnapshot = NetworkSnapshot(rx: b.rx, tx: b.tx, timestamp: Date().timeIntervalSince1970)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            Log.shared.info("System shutting down / logging out")
        }

        Log.shared.info("All timers scheduled, app running")
    }

    private let infoFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    private func makeInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func noop() {}

    private func setInfoTitle(_ item: NSMenuItem, _ text: String) {
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: infoFont, .foregroundColor: NSColor.labelColor]
        )
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 280

        // Calendar
        let calView = CalendarView()
        let calItem = NSMenuItem()
        calItem.view = calView
        menu.addItem(calItem)
        menu.addItem(NSMenuItem.separator())

        // System info — compact (using attributedTitle for readable text)
        cpuItem = makeInfoItem("CPU:  ...")
        menu.addItem(cpuItem)

        memItem = makeInfoItem("RAM:  ...")
        menu.addItem(memItem)

        battItem = makeInfoItem("Battery:  ...")
        menu.addItem(battItem)

        wifiItem = makeInfoItem("Wi-Fi:  ...")
        menu.addItem(wifiItem)

        diskItem = makeInfoItem("Disk:  ...")
        menu.addItem(diskItem)

        uptimeItem = makeInfoItem("Uptime:  ...")
        menu.addItem(uptimeItem)

        menu.addItem(NSMenuItem.separator())

        // Network
        flagMenuItem = NSMenuItem(title: "External IP: ...", action: #selector(copyExtIP), keyEquivalent: "")
        flagMenuItem.target = self
        menu.addItem(flagMenuItem)

        ipMenuItem = NSMenuItem(title: "Local IP: ...", action: #selector(copyLocalIP), keyEquivalent: "")
        ipMenuItem.target = self
        menu.addItem(ipMenuItem)

        rxTotalItem = makeInfoItem("In: ...  Out: ...")
        menu.addItem(rxTotalItem)

        menu.addItem(NSMenuItem.separator())

        // Claude Usage
        claude5hItem = makeInfoItem("Claude 5h: ...")
        menu.addItem(claude5hItem)

        claude7dItem = makeInfoItem("Claude 7d: ...")
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

    private var tickCount: UInt64 = 0

    private func tick() {
        tickCount += 1
        let now = Date()
        let ts = now.timeIntervalSince1970
        let b = getNetworkBytes()
        let snap = NetworkSnapshot(rx: b.rx, tx: b.tx, timestamp: ts)

        var downStr = "0.0 KB/s", upStr = "0.0 KB/s"
        if let prev = prevSnapshot {
            let dt = ts - prev.timestamp
            if dt > 0 {
                // Guard against counter reset (e.g. wake from sleep)
                let rxDelta = snap.rx >= prev.rx ? snap.rx - prev.rx : snap.rx
                let txDelta = snap.tx >= prev.tx ? snap.tx - prev.tx : snap.tx
                downStr = formatSpeed(Double(rxDelta) / dt)
                upStr   = formatSpeed(Double(txDelta) / dt)
                setInfoTitle(rxTotalItem, "In: \(formatBytes(snap.rx))  Out: \(formatBytes(snap.tx))")
            }
        }

        // Log every 150 ticks (~5 min) as heartbeat
        if tickCount % 150 == 0 {
            Log.shared.info("heartbeat tick=\(tickCount) appMem=\(getAppMemoryMB())MB")
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
        setInfoTitle(cpuItem, String(format: "CPU  %3.0f%%  %@", cpu, String(bars)))

        // Memory
        let mem = getMemoryUsage()
        setInfoTitle(memItem, String(format: "RAM  %.1f / %.0f GB  (%.0f%%)", mem.used, mem.total, mem.pct))

        // Battery
        if let batt = getBatteryInfo() {
            let chargeIcon = batt.charging ? "\u{26A1}" : ""
            setInfoTitle(battItem, String(format: "Bat  %d%% %@ cyc:%d hlth:%d%%", batt.level, chargeIcon, batt.cycleCount, batt.health))
            battItem.isHidden = false
        } else {
            battItem.isHidden = true // desktop Mac — no battery
        }

        // Wi-Fi
        if let wifi = getWiFiInfo() {
            setInfoTitle(wifiItem, "Wi-Fi  \(wifi.ssid)  \(signalBars(wifi.rssi))  \(wifi.rssi)dBm")
        } else {
            setInfoTitle(wifiItem, "Wi-Fi  Not connected")
        }

        // Disk & Uptime
        let disk = getDiskUsage()
        setInfoTitle(diskItem, String(format: "Disk  %.0f / %.0f GB", disk.used, disk.total))
        setInfoTitle(uptimeItem, "Up  \(getUptime())")

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
            setInfoTitle(claude5hItem, "Claude 5h: —")
            setInfoTitle(claude7dItem, "Claude 7d: —")
        }
    }

    private func fetchOrgIdAndUsage(sessionKey: String) {
        guard let url = URL(string: "https://claude.ai/api/organizations") else { return }
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) NetMonitor/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                Log.shared.error("fetchOrgId network error: \(error.localizedDescription)")
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                Log.shared.warn("fetchOrgId HTTP \(http.statusCode)")
            }
            guard let data = data,
                  let orgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = orgs.first,
                  let orgId = first["uuid"] as? String
            else {
                Log.shared.warn("fetchOrgId: failed to parse orgs response")
                DispatchQueue.main.async { [weak self] in guard let self else { return }; self.setInfoTitle(self.claude5hItem, "Claude 5h: Bad key") }
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
            DispatchQueue.main.async { [self] in
                self.setInfoTitle(self.claude5hItem, "Claude 5h: —")
                self.setInfoTitle(self.claude7dItem, "Claude 7d: —")
            }
            return
        }

        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) NetMonitor/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                Log.shared.error("fetchClaudeUsage(session) error: \(error.localizedDescription)")
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 401 {
                Log.shared.warn("fetchClaudeUsage: session expired (HTTP \(http.statusCode))")
                DispatchQueue.main.async { [weak self] in guard let self else { return }; self.setInfoTitle(self.claude5hItem, "Claude 5h: Session expired") }
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

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                Log.shared.error("fetchUsageOAuth error: \(error.localizedDescription)")
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                Log.shared.warn("fetchUsageOAuth HTTP \(http.statusCode)")
            }
            self?.parseUsageResponse(data)
        }.resume()
    }

    private func parseUsageResponse(_ data: Data?) {
        guard let data = data,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let fiveH = j["five_hour"] as? [String: Any],
               let u5 = fiveH["utilization"] as? Double {
                let reset = self.parseResetTime(fiveH["resets_at"] as? String, short: true)
                self.setInfoTitle(self.claude5hItem, String(format: "Claude 5h: %.0f%%%@", u5, reset))
            }
            if let sevenD = j["seven_day"] as? [String: Any],
               let u7 = sevenD["utilization"] as? Double {
                let reset = self.parseResetTime(sevenD["resets_at"] as? String, short: false)
                self.setInfoTitle(self.claude7dItem, String(format: "Claude 7d: %.0f%%%@", u7, reset))
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
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            if let error = error {
                Log.shared.error("fetchGeoIP error: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = j["country_code"] as? String,
                  let ip = j["ip"] as? String
            else {
                Log.shared.warn("fetchGeoIP: failed to parse response")
                return
            }
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

installCrashHandlers()
Log.shared.info("=== Process start, installing crash handlers ===")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// If we get here, app exited normally
Log.shared.info("=== NSApplication.run() returned — normal exit ===")
