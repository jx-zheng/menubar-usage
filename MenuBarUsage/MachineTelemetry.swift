import Darwin
import Foundation
import SystemConfiguration
import IOKit
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
    var minutesRemaining: Int? = nil
    /// Instantaneous charge power in watts, only while charging and only when a reading exists.
    var chargeWatts: Double? = nil

    /// First caption under the percent: source, with watts while charging when known.
    var sourceCaption: String {
        guard source == .charging, let chargeWatts, let watts = ChargeWatts.text(chargeWatts) else {
            return source.label
        }
        return "Charging · \(watts)"
    }

    /// Second caption. Time remaining only when the system reported it.
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

/// One decimal, matching `UsageFormatting.percent`. A trailing .0 is omitted.
/// About 0 W, and anything above a laptop charge rate, is left unset.
private enum ChargeWatts {
    static let maximum = 300.0
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func displayWatts(_ watts: Double) -> Double? {
        guard watts > 0, watts <= maximum else { return nil }
        let tenths = (watts * 10).rounded() / 10
        guard tenths > 0 else { return nil }
        return tenths
    }

    static func text(_ watts: Double) -> String? {
        guard let tenths = displayWatts(watts) else { return nil }
        if abs(tenths - tenths.rounded()) < 0.001 {
            return "\(Int(tenths.rounded())) W"
        }
        return String(format: "%.1f", locale: posix, tenths) + " W"
    }
}

struct ChargePowerReading: Equatable {
    var voltageMillivolts: Double? = nil
    var currentMilliamps: Double? = nil
    /// `AdapterDetails.Watts`: negotiated adapter capability, not instantaneous draw.
    var adapterWatts: Double? = nil

    static let empty = ChargePowerReading()
}

enum BatteryStatusParser {
    static func choose(_ descriptions: [[String: Any]], power: ChargePowerReading = .empty) -> BatteryStatus? {
        let parsed: [(BatteryStatus, Bool)] = descriptions.compactMap { description in
            guard let status = parse(description, power: power) else { return nil }
            let transport = description[kIOPSTransportTypeKey as String] as? String
            return (status, transport == (kIOPSInternalType as String))
        }
        return parsed.first(where: \.1)?.0 ?? parsed.first?.0
    }

    static func parse(_ description: [String: Any], power: ChargePowerReading = .empty) -> BatteryStatus? {
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
        let watts = charging ? chargeWatts(iops: description, registry: power) : nil
        return BatteryStatus(
            percent: percent,
            source: source,
            minutesRemaining: minutes,
            chargeWatts: watts
        )
    }

    /// `Voltage` (mV) and `InstantAmperage` (mA) from an AppleSmartBattery snapshot.
    static func powerReading(registryProperties: [String: Any]) -> ChargePowerReading {
        ChargePowerReading(
            voltageMillivolts: positive(registryProperties["Voltage"]),
            currentMilliamps: sample(registryProperties["InstantAmperage"]),
            adapterWatts: adapterWatts(registryProperties["AdapterDetails"])
        )
    }

    /// Instantaneous charge power is voltage (mV) × current (mA) / 1_000_000
    /// when current is positive.
    ///
    /// Current is the IOPS `Current` key when that key yields a finite sample
    /// (0 included); otherwise AppleSmartBattery `InstantAmperage`. Voltage is
    /// IOPS `Voltage` when it is positive; otherwise AppleSmartBattery `Voltage`.
    /// `AdapterDetails.Watts` is the negotiated adapter tier and is used only
    /// when voltage or current is missing, so the product cannot be formed.
    /// A present current that is not positive, or a formed product that is
    /// about 0 W or above a laptop charge rate, stays unset and the caption
    /// is `Charging` with no number.
    private static func chargeWatts(iops: [String: Any], registry: ChargePowerReading) -> Double? {
        let voltage = positive(iops[kIOPSVoltageKey as String]) ?? registry.voltageMillivolts
        let current = sample(iops[kIOPSCurrentKey as String]) ?? registry.currentMilliamps
        if let current {
            if current <= 0 { return nil }
            guard let voltage else {
                return registry.adapterWatts.flatMap(ChargeWatts.displayWatts)
            }
            return ChargeWatts.displayWatts(voltage * current / 1_000_000)
        }
        return registry.adapterWatts.flatMap(ChargeWatts.displayWatts)
    }

    /// Finite reading, including 0. Nil when the value is missing or not finite,
    /// so a present 0 still wins over a fallback (`0 ?? other` stays 0).
    private static func sample(_ value: Any?) -> Double? {
        guard let number = number(value), number.isFinite else { return nil }
        return number
    }

    private static func positive(_ value: Any?) -> Double? {
        sample(value).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func adapterWatts(_ value: Any?) -> Double? {
        // Swift dictionaries are not covariant, so a `[String: Int]` payload
        // does not cast to `[String: Any]`. NSDictionary bridging covers both.
        guard let details = value as? NSDictionary else { return nil }
        return positive(details["Watts"])
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

    fileprivate static func boolValue(_ value: Any?) -> Bool? {
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
    /// How long a resolved interface name is reused.
    static let refreshInterval: TimeInterval = 45

    private static var store: SCDynamicStore?
    private static var cache = TimedCache<String?>(ttl: refreshInterval)

    static func name(now: Date = Date()) -> String? {
        if store == nil {
            store = SCDynamicStoreCreate(nil, "com.jxzheng.menubar-usage" as CFString, nil, nil)
        }
        return cache.resolve(now: now) { readPrimary() }
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

struct DiskStatus: Equatable, Sendable {
    var freeBytes: UInt64
    var totalBytes: UInt64

    var usedBytes: UInt64 {
        totalBytes > freeBytes ? totalBytes - freeBytes : 0
    }

    /// Used share of the volume, on the same 0–100 scale as memory.
    /// `DiskSampler` only builds a value when `totalBytes` is positive.
    var usedPercent: Double {
        Double(usedBytes) / Double(totalBytes) * 100
    }

    /// Free space only, in the Finder units `ByteText.fileString` already uses.
    var freeCaption: String {
        "\(ByteText.fileString(freeBytes)) free"
    }

    /// Used space against the volume size.
    var usedCaption: String {
        "\(ByteText.fileString(usedBytes)) used of \(ByteText.fileString(totalBytes))"
    }
}

/// Startup volume (`/`), which is the internal disk on a Mac that boots from it.
///
/// Free space is `volumeAvailableCapacityForImportantUsage` only — the figure
/// Finder shows, including space it can purge. That value is not cached, so
/// the caller reads it off the main thread and only on the slow cadence.
/// A nil result leaves the last good sample.
enum DiskSampler {
    static func read() -> DiskStatus? {
        let volume = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let free = values.volumeAvailableCapacityForImportantUsage, free >= 0 else { return nil }
        return DiskStatus(freeBytes: UInt64(free), totalBytes: UInt64(total))
    }
}

/// AppleSmartBattery keys for charge watts, read while any source is charging.
/// `Voltage` is mV. `InstantAmperage` is mA. `AdapterDetails` is the negotiated adapter.
enum SmartBatteryPower {
    private static let keys = [
        "Voltage",
        "InstantAmperage",
        "AdapterDetails"
    ]

    static func read() -> ChargePowerReading {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return .empty }
        defer { IOObjectRelease(service) }

        var properties: [String: Any] = [:]
        for key in keys {
            if let value = copyProperty(service, key: key) {
                properties[key] = value
            }
        }
        return BatteryStatusParser.powerReading(registryProperties: properties)
    }

    /// One registry value. The Create call returns +1, so the result is consumed here.
    private static func copyProperty(_ service: io_registry_entry_t, key: String) -> Any? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return unmanaged.takeRetainedValue()
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
        let charging = descriptions.contains {
            BatteryStatusParser.boolValue($0[kIOPSIsChargingKey as String]) == true
        }
        let power = charging ? SmartBatteryPower.read() : .empty
        return BatteryStatusParser.choose(descriptions, power: power)
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
