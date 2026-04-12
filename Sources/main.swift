import Cocoa
import Darwin

// MARK: - Network Stats

struct NetworkSnapshot {
    let rx: UInt64
    let tx: UInt64
    let timestamp: TimeInterval
}

func getNetworkBytes() -> (rx: UInt64, tx: UInt64) {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
    defer { freeifaddrs(firstAddr) }

    var totalRx: UInt64 = 0
    var totalTx: UInt64 = 0
    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr

    while let addr = ptr {
        let name = String(cString: addr.pointee.ifa_name)
        let family = addr.pointee.ifa_addr?.pointee.sa_family ?? 0
        if family == UInt8(AF_LINK), name.hasPrefix("en") {
            if let data = addr.pointee.ifa_data {
                let ifData = data.assumingMemoryBound(to: if_data.self)
                totalRx += UInt64(ifData.pointee.ifi_ibytes)
                totalTx += UInt64(ifData.pointee.ifi_obytes)
            }
        }
        ptr = addr.pointee.ifa_next
    }
    return (totalRx, totalTx)
}

func getLocalIP() -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return "N/A" }
    defer { freeifaddrs(firstAddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let addr = ptr {
        let name = String(cString: addr.pointee.ifa_name)
        let family = addr.pointee.ifa_addr?.pointee.sa_family ?? 0
        if family == UInt8(AF_INET), name.hasPrefix("en") {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr.pointee.ifa_addr, socklen_t(addr.pointee.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            )
            if result == 0 {
                let ip = String(cString: hostname)
                if ip != "127.0.0.1" { return ip }
            }
        }
        ptr = addr.pointee.ifa_next
    }
    return "N/A"
}

// Fixed-width: always "X.X KB/s" or "XXX KB/s" or "X.X MB/s" etc
func formatSpeed(_ bytesPerSec: Double) -> String {
    let kb = bytesPerSec / 1024
    let mb = kb / 1024
    if mb >= 10    { return String(format: "%3.0f MB/s", mb) }
    else if mb >= 1 { return String(format: "%3.1f MB/s", mb) }
    else if kb >= 10 { return String(format: "%3.0f KB/s", kb) }
    else             { return String(format: "%3.1f KB/s", kb) }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1.0 { return String(format: "%.2f GB", gb) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

func countryFlag(_ code: String) -> String {
    let base: UInt32 = 127397
    return String(code.uppercased().unicodeScalars.compactMap {
        UnicodeScalar(base + $0.value)
    }.map { Character($0) })
}

// MARK: - Status View (menu bar)

class StatusView: NSView {
    // Speed: two small lines on the left
    private let speedTop = NSTextField(labelWithString: "")
    private let speedBot = NSTextField(labelWithString: "")
    // Date+time: one normal line on the right, vertically centered
    private let dateTime = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)

        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let normalFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        for label in [speedTop, speedBot] {
            label.font = smallFont
            label.textColor = .headerTextColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }

        dateTime.font = normalFont
        dateTime.textColor = .headerTextColor
        dateTime.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dateTime)

        NSLayoutConstraint.activate([
            speedTop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speedTop.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            speedBot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speedBot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            dateTime.leadingAnchor.constraint(equalTo: speedTop.trailingAnchor, constant: 6),
            dateTime.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateTime.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])

        speedTop.stringValue = "\u{2193}   0.0 KB/s"
        speedBot.stringValue = "\u{2191}   0.0 KB/s"
        dateTime.stringValue = "..."
    }

    required init?(coder: NSCoder) { nil }

    // Pass clicks through to the button underneath so the menu opens
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateSpeed(down: String, up: String) {
        speedTop.stringValue = "\u{2193} \(down)"
        speedBot.stringValue = "\u{2191} \(up)"
    }

    func updateDateTime(_ str: String) {
        dateTime.stringValue = str
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: StatusView!
    private var timer: Timer?
    private var flagTimer: Timer?
    private var prevSnapshot: NetworkSnapshot?

    private var flagMenuItem: NSMenuItem!
    private var ipMenuItem: NSMenuItem!
    private var extIPMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!

    private var currentExtIP = ""
    private var currentFlag = ""

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d MMM  HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let barHeight = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: 210)
        statusView = StatusView(frame: NSRect(x: 0, y: 0, width: 210, height: barHeight))
        statusItem.button?.addSubview(statusView)
        statusView.frame = statusItem.button!.bounds
        statusView.autoresizingMask = [.width, .height]

        buildMenu()
        startMonitoring()
        fetchGeoIP()

        flagTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchGeoIP()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Calendar
        let datePicker = NSDatePicker()
        datePicker.datePickerStyle = .clockAndCalendar
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = Date()
        datePicker.isBezeled = false
        datePicker.drawsBackground = false
        datePicker.translatesAutoresizingMaskIntoConstraints = false

        let calContainer = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 190))
        calContainer.addSubview(datePicker)
        datePicker.frame = NSRect(x: 10, y: 5, width: 220, height: 180)

        let calItem = NSMenuItem()
        calItem.view = calContainer
        menu.addItem(calItem)

        menu.addItem(NSMenuItem.separator())

        // Flag + external IP
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

        let quitItem = NSMenuItem(title: "Quit NetMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func startMonitoring() {
        let bytes = getNetworkBytes()
        prevSnapshot = NetworkSnapshot(rx: bytes.rx, tx: bytes.tx, timestamp: Date().timeIntervalSince1970)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func updateStats() {
        let now = Date()
        let ts = now.timeIntervalSince1970
        let bytes = getNetworkBytes()
        let current = NetworkSnapshot(rx: bytes.rx, tx: bytes.tx, timestamp: ts)

        if let prev = prevSnapshot {
            let dt = ts - prev.timestamp
            guard dt > 0 else { return }
            let rxSpeed = Double(current.rx - prev.rx) / dt
            let txSpeed = Double(current.tx - prev.tx) / dt
            statusView.updateSpeed(down: formatSpeed(rxSpeed), up: formatSpeed(txSpeed))
            rxTotalItem.title = "Total In:  \(formatBytes(current.rx))"
            txTotalItem.title = "Total Out: \(formatBytes(current.tx))"
        }

        // Capitalize first letter of day name
        var dateStr = dateFormatter.string(from: now)
        if let first = dateStr.first {
            dateStr = first.uppercased() + dateStr.dropFirst()
        }
        statusView.updateDateTime(dateStr)

        ipMenuItem.title = "Local IP: \(getLocalIP())"
        prevSnapshot = current
    }

    private func fetchGeoIP() {
        guard let url = URL(string: "http://ip-api.com/json/?fields=query,countryCode") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["countryCode"] as? String,
                  let ip = json["query"] as? String
            else { return }
            let flag = countryFlag(code)
            DispatchQueue.main.async {
                self?.currentExtIP = ip
                self?.currentFlag = flag
                self?.flagMenuItem.title = "\(flag) External IP: \(ip)"
            }
        }.resume()
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

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
