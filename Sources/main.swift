import Cocoa
import Darwin
import CoreWLAN

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

// MARK: - System info

func getCPUUsage() -> Double {
    var loadInfo = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &loadInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let user = Double(loadInfo.cpu_ticks.0)
    let sys  = Double(loadInfo.cpu_ticks.1)
    let idle = Double(loadInfo.cpu_ticks.2)
    let nice = Double(loadInfo.cpu_ticks.3)
    let total = user + sys + idle + nice
    return total > 0 ? ((user + sys + nice) / total) * 100 : 0
}

struct PerCoreCPU {
    let usage: [Double] // percentage per logical core
}

func getPerCoreCPU() -> PerCoreCPU {
    let numCPU = Int32(ProcessInfo.processInfo.processorCount)
    var cpuInfo: processor_info_array_t?
    var numCPUInfo: mach_msg_type_number_t = 0
    var numCPUs: natural_t = 0

    let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCPUInfo)
    guard result == KERN_SUCCESS, let info = cpuInfo else { return PerCoreCPU(usage: []) }

    var usages: [Double] = []
    for i in 0..<Int(numCPUs) {
        let offset = Int(CPU_STATE_MAX) * i
        let user   = Double(info[offset + Int(CPU_STATE_USER)])
        let sys    = Double(info[offset + Int(CPU_STATE_SYSTEM)])
        let idle   = Double(info[offset + Int(CPU_STATE_IDLE)])
        let nice   = Double(info[offset + Int(CPU_STATE_NICE)])
        let total = user + sys + idle + nice
        let pct = total > 0 ? ((user + sys + nice) / total) * 100 : 0
        usages.append(pct)
    }

    let size = Int(numCPUInfo) * MemoryLayout<integer_t>.size
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(size))

    return PerCoreCPU(usage: usages)
}

func getMemoryUsage() -> (used: Double, total: Double, pct: Double) {
    let total = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let pageSize = Double(vm_kernel_page_size)

    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, total, 0) }

    let active     = Double(stats.active_count) * pageSize
    let wired      = Double(stats.wire_count) * pageSize
    let compressed = Double(stats.compressor_page_count) * pageSize
    let used = (active + wired + compressed) / (1024 * 1024 * 1024)
    let pct = total > 0 ? (used / total) * 100 : 0
    return (used, total, pct)
}

func getDiskUsage() -> (used: Double, total: Double) {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
        let free  = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        return ((total - free) / (1024 * 1024 * 1024), total / (1024 * 1024 * 1024))
    } catch { return (0, 0) }
}

func getUptime() -> String {
    let ti = ProcessInfo.processInfo.systemUptime
    let d = Int(ti) / 86400, h = (Int(ti) % 86400) / 3600, m = (Int(ti) % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

struct WiFiInfo {
    let ssid: String
    let rssi: Int // dBm
    let bars: String
}

func getWiFiInfo() -> WiFiInfo? {
    guard let iface = CWWiFiClient.shared().interface(),
          let ssid = iface.ssid() else { return nil }
    let rssi = iface.rssiValue()
    let bars: String
    switch rssi {
    case -50...0:    bars = "\u{2587}\u{2587}\u{2587}\u{2587}"
    case -60...(-51): bars = "\u{2587}\u{2587}\u{2587}\u{2581}"
    case -70...(-61): bars = "\u{2587}\u{2587}\u{2581}\u{2581}"
    default:          bars = "\u{2587}\u{2581}\u{2581}\u{2581}"
    }
    return WiFiInfo(ssid: ssid, rssi: rssi, bars: bars)
}

// MARK: - Render menu bar image

func renderStatusImage(up: String, down: String, dateStr: String, timeStr: String, height: CGFloat) -> NSImage {
    let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let dateFont  = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let timeFont  = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    let black: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]

    let speedAttrs = black.merging([.font: speedFont]) { $1 }
    let dateAttrs  = black.merging([.font: dateFont]) { $1 }
    let timeAttrs  = black.merging([.font: timeFont]) { $1 }

    let upStr   = "\u{2191} \(up)"
    let downStr = "\u{2193} \(down)"

    let upSize   = (upStr as NSString).size(withAttributes: speedAttrs)
    let downSize = (downStr as NSString).size(withAttributes: speedAttrs)
    let dateSize = (dateStr as NSString).size(withAttributes: dateAttrs)
    let timeSize = (timeStr as NSString).size(withAttributes: timeAttrs)

    let speedW = max(upSize.width, downSize.width)
    let gap: CGFloat = 4
    let totalW = ceil(speedW + gap + dateSize.width + 3 + timeSize.width)

    let img = NSImage(size: NSSize(width: totalW, height: height))
    img.lockFocus()

    let lineH = height / 2
    (upStr as NSString).draw(at: NSPoint(x: 0, y: lineH + 1), withAttributes: speedAttrs)
    (downStr as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: speedAttrs)

    let dtX = speedW + gap
    let dateY = (height - dateSize.height) / 2
    (dateStr as NSString).draw(at: NSPoint(x: dtX, y: dateY), withAttributes: dateAttrs)

    let timeX = dtX + dateSize.width + 3
    let timeY = (height - timeSize.height) / 2
    (timeStr as NSString).draw(at: NSPoint(x: timeX, y: timeY), withAttributes: timeAttrs)

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
    private var colonVisible = true

    // Menu items
    private var cpuTotalItem: NSMenuItem!
    private var cpuCoreItems: [NSMenuItem] = []
    private var memItem: NSMenuItem!
    private var wifiItem: NSMenuItem!
    private var flagMenuItem: NSMenuItem!
    private var ipMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!
    private var diskItem: NSMenuItem!
    private var uptimeItem: NSMenuItem!
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
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetchGeoIP() }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Calendar
        let dp = NSDatePicker()
        dp.datePickerStyle = .clockAndCalendar
        dp.datePickerElements = .yearMonthDay
        dp.dateValue = Date()
        dp.isBezeled = false
        dp.drawsBackground = false
        dp.frame = NSRect(x: 8, y: 4, width: 280, height: 200)
        let calBox = NSView(frame: NSRect(x: 0, y: 0, width: 296, height: 208))
        calBox.addSubview(dp)
        let calItem = NSMenuItem()
        calItem.view = calBox
        menu.addItem(calItem)

        menu.addItem(NSMenuItem.separator())

        // CPU
        cpuTotalItem = NSMenuItem(title: "CPU:  ...", action: nil, keyEquivalent: "")
        cpuTotalItem.isEnabled = false
        menu.addItem(cpuTotalItem)

        let numCores = ProcessInfo.processInfo.processorCount
        for i in 0..<numCores {
            let prefix = i == numCores - 1 ? "\u{2514}" : "\u{251C}"
            let item = NSMenuItem(title: "  \(prefix) Core \(i + 1):  ...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            cpuCoreItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Memory
        memItem = NSMenuItem(title: "Memory:  ...", action: nil, keyEquivalent: "")
        memItem.isEnabled = false
        menu.addItem(memItem)

        menu.addItem(NSMenuItem.separator())

        // Wi-Fi
        wifiItem = NSMenuItem(title: "Wi-Fi:  ...", action: nil, keyEquivalent: "")
        wifiItem.isEnabled = false
        menu.addItem(wifiItem)

        menu.addItem(NSMenuItem.separator())

        // Network IPs
        flagMenuItem = NSMenuItem(title: "External IP: ...", action: #selector(copyExtIP), keyEquivalent: "")
        flagMenuItem.target = self
        menu.addItem(flagMenuItem)

        ipMenuItem = NSMenuItem(title: "Local IP: ...", action: #selector(copyLocalIP), keyEquivalent: "")
        ipMenuItem.target = self
        menu.addItem(ipMenuItem)

        menu.addItem(NSMenuItem.separator())

        rxTotalItem = NSMenuItem(title: "Total In:  ...", action: nil, keyEquivalent: "")
        rxTotalItem.isEnabled = false
        menu.addItem(rxTotalItem)

        txTotalItem = NSMenuItem(title: "Total Out: ...", action: nil, keyEquivalent: "")
        txTotalItem.isEnabled = false
        menu.addItem(txTotalItem)

        menu.addItem(NSMenuItem.separator())

        diskItem = NSMenuItem(title: "Disk:  ...", action: nil, keyEquivalent: "")
        diskItem.isEnabled = false
        menu.addItem(diskItem)

        uptimeItem = NSMenuItem(title: "Uptime:  ...", action: nil, keyEquivalent: "")
        uptimeItem.isEnabled = false
        menu.addItem(uptimeItem)

        menu.addItem(NSMenuItem.separator())

        let termItem = NSMenuItem(title: "Terminal", action: #selector(openTerminal), keyEquivalent: "t")
        termItem.target = self
        menu.addItem(termItem)

        let actItem = NSMenuItem(title: "Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "a")
        actItem.target = self
        menu.addItem(actItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit NetMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func startMonitoring() {
        let b = getNetworkBytes()
        prevSnapshot = NetworkSnapshot(rx: b.rx, tx: b.tx, timestamp: Date().timeIntervalSince1970)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
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
                rxTotalItem.title = "Total In:  \(formatBytes(snap.rx))"
                txTotalItem.title = "Total Out: \(formatBytes(snap.tx))"
            }
        }

        // Date
        var dateStr = dateFmt.string(from: now)
        if let c = dateStr.first { dateStr = c.uppercased() + dateStr.dropFirst() }

        // Time with blinking colons
        colonVisible.toggle()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let s = cal.component(.second, from: now)
        let sep = colonVisible ? ":" : " "
        let timeStr = String(format: "%02d%@%02d%@%02d", h, sep, m, sep, s)

        let img = renderStatusImage(up: upStr, down: downStr, dateStr: dateStr, timeStr: timeStr, height: barHeight)
        statusItem.button?.image = img

        // CPU
        let cpu = getCPUUsage()
        cpuTotalItem.title = String(format: "CPU Total:    %4.0f%%", cpu)

        let cores = getPerCoreCPU()
        for (i, item) in cpuCoreItems.enumerated() {
            let prefix = i == cpuCoreItems.count - 1 ? "\u{2514}" : "\u{251C}"
            if i < cores.usage.count {
                item.title = String(format: "  %@ Core %d:   %4.0f%%", prefix, i + 1, cores.usage[i])
            }
        }

        // Memory
        let mem = getMemoryUsage()
        memItem.title = String(format: "Memory:   %.1f / %.0f GB  (%.0f%%)", mem.used, mem.total, mem.pct)

        // Wi-Fi
        if let wifi = getWiFiInfo() {
            wifiItem.title = "Wi-Fi:   \(wifi.ssid)  \(wifi.bars)  \(wifi.rssi) dBm"
        } else {
            wifiItem.title = "Wi-Fi:   Not connected"
        }

        // Disk & Uptime
        let disk = getDiskUsage()
        diskItem.title = String(format: "Disk:    %.0f / %.0f GB", disk.used, disk.total)
        uptimeItem.title = "Uptime:  \(getUptime())"

        ipMenuItem.title = "Local IP: \(getLocalIP())"
        prevSnapshot = snap
    }

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
                self?.flagMenuItem.title = "\(countryFlag(code))  External IP: \(ip)"
            }
        }.resume()
    }

    @objc private func openTerminal() {
        NSWorkspace.shared.launchApplication("Terminal")
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.launchApplication("Activity Monitor")
    }

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
