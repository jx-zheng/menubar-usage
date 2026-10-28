import Darwin
import Foundation
import SystemConfiguration
import IOKit.ps

struct LinkReading: Equatable {
    var name: String
    var isUp: Bool
    var isLoopback: Bool
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum InterfaceSelection {
    /// Prefer the primary interface so a VPN is not added on top of the
    /// physical NIC. Otherwise sum the up `en` interfaces.
    static func totals(interfaces: [LinkReading], primary: String?) -> (bytesIn: UInt64, bytesOut: UInt64)? {
        let active = interfaces.filter { $0.isUp && !$0.isLoopback }
        if let primary, let match = active.first(where: { $0.name == primary }) {
            return (match.bytesIn, match.bytesOut)
        }
        let physical = active.filter { $0.name.hasPrefix("en") }
        guard !physical.isEmpty else { return nil }
        let bytesIn = physical.reduce(UInt64(0)) { $0 + $1.bytesIn }
        let bytesOut = physical.reduce(UInt64(0)) { $0 + $1.bytesOut }
        return (bytesIn, bytesOut)
    }
}

enum Throughput {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Decimal units, matching how link speeds are usually quoted.
    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let units: [(Double, String)] = [
            (1_000_000_000, "GB/s"),
            (1_000_000, "MB/s"),
            (1_000, "KB/s")
        ]
        for (divisor, unit) in units where value >= divisor {
            let scaled = value / divisor
            if scaled >= 100 || abs(scaled.rounded() - scaled) < 0.05 {
                return "\(Int(scaled.rounded())) \(unit)"
            }
            let text = String(format: "%.1f", locale: posix, scaled)
            return "\(text) \(unit)"
        }
        return "\(Int(value.rounded())) B/s"
    }

    /// Nil when the interval is too short, the counter reset, or the jump is not a real rate.
    static func bytesPerSecond(previous: UInt64, current: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds >= 0.2, current >= previous else { return nil }
        let rate = Double(current - previous) / seconds
        guard rate.isFinite, rate <= 10_000_000_000 else { return nil }
        return rate
    }
}

enum BatterySource: Equatable {
    case charging
    case powerAdapter
    case battery

    var label: String {
        switch self {
        case .charging: return "Charging"
        case .powerAdapter: return "AC power"
        case .battery: return "On battery"
        }
    }
}

struct BatteryStatus: Equatable {
    var percent: Double
    var source: BatterySource
    var minutesRemaining: Int?

    var timeCaption: String? {
        guard let minutesRemaining, minutesRemaining > 0 else { return nil }
        let duration = Self.duration(minutesRemaining)
        switch source {
        case .charging: return "\(duration) to full"
        case .battery: return "\(duration) left"
        case .powerAdapter: return nil
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }
}

enum BatteryStatusParser {
    static func choose(_ descriptions: [[String: Any]]) -> BatteryStatus? {
        let parsed: [(BatteryStatus, Bool)] = descriptions.compactMap { description in
            guard let status = parse(description) else { return nil }
            let transport = description[kIOPSTransportTypeKey as String] as? String
            return (status, transport == (kIOPSInternalType as String))
        }
        return parsed.first(where: \.1)?.0 ?? parsed.first?.0
    }

    static func parse(_ description: [String: Any]) -> BatteryStatus? {
        if boolValue(description[kIOPSIsPresentKey as String]) == false { return nil }
        guard let current = number(description[kIOPSCurrentCapacityKey as String]),
              let maximum = number(description[kIOPSMaxCapacityKey as String]),
              maximum > 0 else { return nil }
        let percent = min(100, max(0, current / maximum * 100))
        let state = description[kIOPSPowerSourceStateKey as String] as? String
        let charging = boolValue(description[kIOPSIsChargingKey as String]) == true
        let onBattery = state == (kIOPSBatteryPowerValue as String)
        let source: BatterySource = charging ? .charging : (onBattery ? .battery : .powerAdapter)
        let minutes: Int?
        if charging {
            minutes = minutesRemaining(description[kIOPSTimeToFullChargeKey as String])
        } else if onBattery {
            minutes = minutesRemaining(description[kIOPSTimeToEmptyKey as String])
        } else {
            minutes = nil
        }
        return BatteryStatus(percent: percent, source: source, minutesRemaining: minutes)
    }

    private static func minutesRemaining(_ value: Any?) -> Int? {
        guard let minutes = number(value).map({ Int($0.rounded()) }), minutes > 0 else { return nil }
        return minutes
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: return value.isFinite ? value : nil
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as NSNumber: return value.boolValue
        default: return nil
        }
    }
}

enum LinkCounters {
    static func read() -> [LinkReading] {
        var name: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0, length > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        let copied = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return sysctl(&name, u_int(name.count), base, &length, nil, 0)
        }
        guard copied == 0 else { return [] }
        let available = min(length, buffer.count)
        var readings: [LinkReading] = []
        var offset = 0
        while offset + MemoryLayout<if_msghdr2>.size <= available {
            let header: if_msghdr2 = buffer.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
            }
            let messageLength = Int(header.ifm_msglen)
            guard messageLength > 0, offset + messageLength <= available else { break }
            if header.ifm_type == UInt8(RTM_IFINFO2),
               let interfaceName = interfaceName(buffer, headerOffset: offset, messageLength: messageLength) {
                readings.append(LinkReading(
                    name: interfaceName,
                    isUp: (header.ifm_flags & Int32(IFF_UP)) != 0,
                    isLoopback: (header.ifm_flags & Int32(IFF_LOOPBACK)) != 0,
                    bytesIn: header.ifm_data.ifi_ibytes,
                    bytesOut: header.ifm_data.ifi_obytes
                ))
            }
            offset += messageLength
        }
        return readings
    }

    /// `sdl_data` starts 8 bytes into `sockaddr_dl`.
    private static func interfaceName(_ buffer: [UInt8], headerOffset: Int, messageLength: Int) -> String? {
        let address = headerOffset + MemoryLayout<if_msghdr2>.size
        let limit = headerOffset + messageLength
        guard address + 8 <= limit else { return nil }
        let length = Int(buffer[address + 5])
        guard length > 0, address + 8 + length <= limit, length < Int(IFNAMSIZ) else { return nil }
        let bytes = buffer[(address + 8)..<(address + 8 + length)]
        return String(bytes: bytes, encoding: .utf8)
    }
}

enum PrimaryInterface {
    /// How long a resolved interface name is reused. Notifications mark it stale sooner.
    static let refreshInterval: TimeInterval = 45

    private static let queue = DispatchQueue(label: "com.jxzheng.menubar-usage.primary-interface")
    private static let setupLock = NSLock()
    private static var store: SCDynamicStore?
    private static var ready = false
    private static var cache = TimedCache<String?>(ttl: refreshInterval)

    private static let changeCallback: SCDynamicStoreCallBack = { _, _, _ in
        PrimaryInterface.noteStoreChange()
    }

    static func name(now: Date = Date()) -> String? {
        ensureStore()
        return queue.sync {
            cache.resolve(now: now) { readPrimary() }.value
        }
    }

    /// One store for the process. Key changes mark the cached interface stale;
    /// the next sample reads it again, and the name is also refreshed on `refreshInterval`.
    private static func ensureStore() {
        setupLock.lock()
        defer { setupLock.unlock() }
        guard !ready else { return }
        ready = true
        guard let created = SCDynamicStoreCreate(
            nil,
            "com.jxzheng.menubar-usage" as CFString,
            changeCallback,
            nil
        ) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        SCDynamicStoreSetNotificationKeys(created, keys, nil)
        SCDynamicStoreSetDispatchQueue(created, queue)
        store = created
    }

    private static func noteStoreChange() {
        // Hop onto `queue` even when the callback is already there, so this never
        // `sync`s the queue it is running on. `name()` is the other writer.
        queue.async {
            cache.markStale()
        }
    }

    private static func readPrimary() -> String? {
        guard let store else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString),
                  let dictionary = value as? [String: Any],
                  let interface = dictionary["PrimaryInterface"] as? String,
                  !interface.isEmpty else { continue }
            return interface
        }
        return nil
    }
}

enum BatterySampler {
    private static let powerCallback: IOPowerSourceCallbackType = { _ in
        BatterySampler.deliverChange()
    }
    private static var onChange: (() -> Void)?
    private static var runLoopSource: CFRunLoopSource?

    /// Fires on the main queue when a power source is added, removed, or changes state.
    static func startWatching(_ update: @escaping () -> Void) {
        onChange = update
        guard runLoopSource == nil else { return }
        guard let created = IOPSNotificationCreateRunLoopSource(powerCallback, nil) else { return }
        let source = created.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private static func deliverChange() {
        let update = onChange
        DispatchQueue.main.async {
            update?()
        }
    }

    static func read() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        let descriptions: [[String: Any]] = list.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() else {
                return nil
            }
            return description as? [String: Any]
        }
        return BatteryStatusParser.choose(descriptions)
    }
}

enum SampleHistory {
    static func append<T>(_ value: T, to history: inout [T], limit: Int) {
        history.append(value)
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}
