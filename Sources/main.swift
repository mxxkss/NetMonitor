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

// Fixed-width speed: always 8 chars like "3.5 KB/s" or "120 MB/s"
func formatSpeed(_ bytesPerSec: Double) -> String {
    let kb = bytesPerSec / 1024
    let mb = kb / 1024

    if mb >= 10 {
        return String(format: "%3.0f MB/s", mb)
    } else if mb >= 1 {
        return String(format: "%3.1f MB/s", mb)
    } else if kb >= 10 {
        return String(format: "%3.0f KB/s", kb)
    } else {
        return String(format: "%3.1f KB/s", kb)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1.0 { return String(format: "%.2f GB", gb) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}

func countryFlag(_ code: String) -> String {
    let base: UInt32 = 127397 // 0x1F1E6 - 65
    return String(code.uppercased().unicodeScalars.compactMap {
        UnicodeScalar(base + $0.value)
    }.map { Character($0) })
}

// MARK: - Status View (menu bar two-line layout)

class StatusView: NSView {
    private let speedTopLabel = NSTextField(labelWithString: "")
    private let speedBotLabel = NSTextField(labelWithString: "")
    private let flagLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")

    private let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private let flagFont = NSFont.systemFont(ofSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)

        for label in [speedTopLabel, speedBotLabel, dateLabel, timeLabel] {
            label.font = speedFont
            label.textColor = .headerTextColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        dateLabel.font = dateFont
        timeLabel.font = dateFont

        flagLabel.font = flagFont
        flagLabel.textColor = .headerTextColor
        flagLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flagLabel)

        NSLayoutConstraint.activate([
            // Speed labels — left
            speedTopLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speedTopLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            speedBotLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            speedBotLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            // Flag — middle
            flagLabel.leadingAnchor.constraint(equalTo: speedTopLabel.trailingAnchor, constant: 4),
            flagLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Date/time — right
            dateLabel.leadingAnchor.constraint(equalTo: flagLabel.trailingAnchor, constant: 3),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            timeLabel.leadingAnchor.constraint(equalTo: flagLabel.trailingAnchor, constant: 3),
            timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])

        speedTopLabel.stringValue = "\u{2193} ... KB/s"
        speedBotLabel.stringValue = "\u{2191} ... KB/s"
        flagLabel.stringValue = "\u{1F3F3}"
        dateLabel.stringValue = "..."
        timeLabel.stringValue = "..."
    }

    required init?(coder: NSCoder) { nil }

    func updateSpeed(down: String, up: String) {
        speedTopLabel.stringValue = "\u{2193} \(down)"
        speedBotLabel.stringValue = "\u{2191} \(up)"
    }

    func updateFlag(_ flag: String) {
        flagLabel.stringValue = flag
    }

    func updateDateTime(date: String, time: String) {
        dateLabel.stringValue = date
        timeLabel.stringValue = time
    }
}

// MARK: - Calendar View for menu

class CalendarViewController: NSView {
    private var datePicker: NSDatePicker!
    private var monthLabel: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var displayedDate: Date

    override init(frame: NSRect) {
        self.displayedDate = Date()
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        self.displayedDate = Date()
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        datePicker = NSDatePicker()
        datePicker.datePickerStyle = .clockAndCalendar
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = Date()
        datePicker.isBezeled = false
        datePicker.drawsBackground = false
        datePicker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(datePicker)

        NSLayoutConstraint.activate([
            datePicker.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            datePicker.centerXAnchor.constraint(equalTo: centerXAnchor),
            datePicker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func resetToToday() {
        datePicker.dateValue = Date()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusView: StatusView!
    private var timer: Timer?
    private var flagTimer: Timer?
    private var prevSnapshot: NetworkSnapshot?

    private var ipMenuItem: NSMenuItem!
    private var extIPMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!

    private var currentFlag = "\u{1F3F3}"
    private var currentExtIP = ""

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d MMM"
        return f
    }()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let barHeight = NSStatusBar.system.thickness
        statusItem = NSStatusBar.system.statusItem(withLength: 220)
        statusView = StatusView(frame: NSRect(x: 0, y: 0, width: 220, height: barHeight))
        statusItem.button?.addSubview(statusView)
        statusView.frame = statusItem.button!.bounds
        statusView.autoresizingMask = [.width, .height]

        buildMenu()
        startMonitoring()
        fetchGeoIP()

        // Refresh geo IP every 10 minutes
        flagTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.fetchGeoIP()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        // Calendar widget
        let calView = CalendarViewController(frame: NSRect(x: 0, y: 0, width: 230, height: 180))
        let calItem = NSMenuItem()
        calItem.view = calView
        menu.addItem(calItem)

        menu.addItem(NSMenuItem.separator())

        ipMenuItem = NSMenuItem(title: "Local IP: ...", action: #selector(copyLocalIP), keyEquivalent: "")
        ipMenuItem.target = self
        menu.addItem(ipMenuItem)

        extIPMenuItem = NSMenuItem(title: "External IP: ...", action: #selector(copyExtIP), keyEquivalent: "")
        extIPMenuItem.target = self
        menu.addItem(extIPMenuItem)

        menu.addItem(NSMenuItem.separator())

        rxTotalItem = NSMenuItem(title: "Total In: ...", action: nil, keyEquivalent: "")
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

        // Update date/time every tick
        let dateStr = dateFormatter.string(from: now)
            .split(separator: " ").enumerated().map { i, s in
                i == 0 ? s.prefix(1).uppercased() + s.dropFirst() : String(s)
            }.joined(separator: " ")
        let timeStr = timeFormatter.string(from: now)
        statusView.updateDateTime(date: dateStr, time: timeStr)

        ipMenuItem.title = "Local IP: \(getLocalIP())  (click to copy)"
        prevSnapshot = current
    }

    private func fetchGeoIP() {
        guard let url = URL(string: "http://ip-api.com/json/?fields=query,countryCode") else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["countryCode"] as? String,
                  let ip = json["query"] as? String
            else { return }

            let flag = countryFlag(code)
            DispatchQueue.main.async {
                self?.currentFlag = flag
                self?.currentExtIP = ip
                self?.statusView.updateFlag(flag)
                self?.extIPMenuItem.title = "External IP: \(ip) \(flag)  (click to copy)"
            }
        }
        task.resume()
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
