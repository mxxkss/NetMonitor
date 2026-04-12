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

func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1024 {
        return String(format: "%.0f B/s", bytesPerSec)
    } else if bytesPerSec < 1024 * 1024 {
        return String(format: "%.1f KB/s", bytesPerSec / 1024)
    } else {
        return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1.0 {
        return String(format: "%.2f GB", gb)
    }
    let mb = Double(bytes) / (1024 * 1024)
    return String(format: "%.1f MB", mb)
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var prevSnapshot: NetworkSnapshot?

    private var ipMenuItem: NSMenuItem!
    private var rxTotalItem: NSMenuItem!
    private var txTotalItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem.button?.title = "Net: ..."

        buildMenu()
        startMonitoring()
    }

    private func buildMenu() {
        let menu = NSMenu()

        ipMenuItem = NSMenuItem(title: "IP: ...", action: #selector(copyIP), keyEquivalent: "c")
        ipMenuItem.target = self
        menu.addItem(ipMenuItem)

        menu.addItem(NSMenuItem.separator())

        rxTotalItem = NSMenuItem(title: "Total In: ...", action: nil, keyEquivalent: "")
        rxTotalItem.isEnabled = false
        menu.addItem(rxTotalItem)

        txTotalItem = NSMenuItem(title: "Total Out: ...", action: nil, keyEquivalent: "")
        txTotalItem.isEnabled = false
        menu.addItem(txTotalItem)

        menu.addItem(NSMenuItem.separator())

        let extIPItem = NSMenuItem(title: "External IP...", action: #selector(fetchExternalIP), keyEquivalent: "e")
        extIPItem.target = self
        menu.addItem(extIPItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit NetMonitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func startMonitoring() {
        let bytes = getNetworkBytes()
        prevSnapshot = NetworkSnapshot(rx: bytes.rx, tx: bytes.tx, timestamp: Date().timeIntervalSince1970)

        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func updateStats() {
        let now = Date().timeIntervalSince1970
        let bytes = getNetworkBytes()
        let current = NetworkSnapshot(rx: bytes.rx, tx: bytes.tx, timestamp: now)

        if let prev = prevSnapshot {
            let dt = now - prev.timestamp
            guard dt > 0 else { return }

            let rxSpeed = Double(current.rx - prev.rx) / dt
            let txSpeed = Double(current.tx - prev.tx) / dt

            statusItem.button?.title = "\u{2193}\(formatSpeed(rxSpeed))  \u{2191}\(formatSpeed(txSpeed))"

            rxTotalItem.title = "Total In:  \(formatBytes(current.rx))"
            txTotalItem.title = "Total Out: \(formatBytes(current.tx))"
        }

        ipMenuItem.title = "IP: \(getLocalIP())  (click to copy)"
        prevSnapshot = current
    }

    @objc private func copyIP() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(getLocalIP(), forType: .string)
    }

    @objc private func fetchExternalIP() {
        let task = URLSession.shared.dataTask(with: URL(string: "https://api.ipify.org")!) { data, _, error in
            DispatchQueue.main.async {
                let ip = data.flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? error?.localizedDescription ?? "Error"
                let alert = NSAlert()
                alert.messageText = "External IP"
                alert.informativeText = ip
                alert.addButton(withTitle: "Copy")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
            }
        }
        task.resume()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
