import Cocoa
import Darwin

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

// MARK: - Render menu bar image

func renderStatusImage(down: String, up: String, dateTime: String, height: CGFloat) -> NSImage {
    let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let color: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.black]

    let speedAttrs: [NSAttributedString.Key: Any] = [.font: speedFont].merging(color) { $1 }
    let dateAttrs: [NSAttributedString.Key: Any] = [.font: dateFont].merging(color) { $1 }

    let downStr = "\u{2193} \(down)"
    let upStr   = "\u{2191} \(up)"

    let downSize = (downStr as NSString).size(withAttributes: speedAttrs)
    let upSize   = (upStr as NSString).size(withAttributes: speedAttrs)
    let dateSize = (dateTime as NSString).size(withAttributes: dateAttrs)

    let speedW = max(downSize.width, upSize.width)
    let gap: CGFloat = 5
    let totalW = ceil(speedW + gap + dateSize.width)

    let img = NSImage(size: NSSize(width: totalW, height: height))
    img.lockFocus()

    // Speed: two lines stacked
    let lineH = height / 2
    (downStr as NSString).draw(at: NSPoint(x: 0, y: lineH + 1), withAttributes: speedAttrs)
    (upStr as NSString).draw(at: NSPoint(x: 0, y: 1), withAttributes: speedAttrs)

    // Date/time: one line, vertically centered, right of speed
    let dateY = (height - dateSize.height) / 2
    (dateTime as NSString).draw(at: NSPoint(x: speedW + gap, y: dateY), withAttributes: dateAttrs)

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

    private var flagMenuItem: NSMenuItem!
    private var ipMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!
    private var currentExtIP = ""

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d MMM  HH:mm:ss"
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
        dp.frame = NSRect(x: 8, y: 4, width: 220, height: 180)

        let calBox = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 188))
        calBox.addSubview(dp)
        let calItem = NSMenuItem()
        calItem.view = calBox
        menu.addItem(calItem)

        menu.addItem(NSMenuItem.separator())

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

        var downStr = "0.0 KB/s"
        var upStr   = "0.0 KB/s"

        if let prev = prevSnapshot {
            let dt = ts - prev.timestamp
            if dt > 0 {
                downStr = formatSpeed(Double(snap.rx - prev.rx) / dt)
                upStr   = formatSpeed(Double(snap.tx - prev.tx) / dt)
                rxTotalItem.title = "Total In:  \(formatBytes(snap.rx))"
                txTotalItem.title = "Total Out: \(formatBytes(snap.tx))"
            }
        }

        var dateStr = dateFmt.string(from: now)
        if let c = dateStr.first { dateStr = c.uppercased() + dateStr.dropFirst() }

        let img = renderStatusImage(down: downStr, up: upStr, dateTime: dateStr, height: barHeight)
        statusItem.button?.image = img

        ipMenuItem.title = "Local IP: \(getLocalIP())"
        prevSnapshot = snap
    }

    private func fetchGeoIP() {
        guard let url = URL(string: "http://ip-api.com/json/?fields=query,countryCode") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = j["countryCode"] as? String,
                  let ip = j["query"] as? String
            else { return }
            DispatchQueue.main.async {
                self?.currentExtIP = ip
                self?.flagMenuItem.title = "\(countryFlag(code))  External IP: \(ip)"
            }
        }.resume()
    }

    @objc private func copyLocalIP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(getLocalIP(), forType: .string)
    }

    @objc private func openTerminal() {
        NSWorkspace.shared.launchApplication("Terminal")
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.launchApplication("Activity Monitor")
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
