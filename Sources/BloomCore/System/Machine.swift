import Foundation
#if os(macOS)
import IOKit
import IOKit.ps
#endif

/// What kind of Mac this is, for the few decisions that turn on it.
///
/// One question so far: whether there is a lid to close. Keeping a Mac awake through a closed lid
/// is worth offering on a laptop and meaningless on a Mac mini, and the welcome window should not
/// ask a desktop to approve a helper it will never use.
public enum Machine {
    /// Whether this Mac has a lid.
    ///
    /// **Not the model identifier, and that was measured rather than assumed.** Amphetamine asks
    /// this question by name ("This Mac is not a book") and every Intel portable answered it with
    /// "Book" in `hw.model`. Apple Silicon does not: a MacBook Pro reports `Mac16,6`, which is the
    /// same shape a Mac Studio reports. The first version of this file used that string and the
    /// test for it failed on the very machine it was written on.
    ///
    /// So the hardware is asked instead, twice, because either answer alone is enough: a power
    /// source of type internal battery, and the `AppleClamshellState` property, which the power
    /// management root publishes on a machine that can be closed and nowhere else. The name is
    /// kept as a last resort for a Mac that answers neither.
    public static func isPortable(model: String, hasInternalBattery: Bool, publishesClamshellState: Bool) -> Bool {
        publishesClamshellState || hasInternalBattery || model.lowercased().contains("book")
    }

    #if os(macOS)
    public static var isPortable: Bool {
        isPortable(
            model: hardwareModel,
            hasInternalBattery: hasInternalBattery,
            publishesClamshellState: publishesClamshellState
        )
    }

    /// Whether the power management root publishes a lid state, which only a portable does.
    static var publishesClamshellState: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(
            root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )
        return state != nil
    }

    /// Whether one of this Mac's power sources is a battery inside it.
    static var hasInternalBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// `hw.model`, or an empty string on a machine that does not answer.
    public static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        // `sysctl` answers with a trailing null, which is not part of the name.
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    #endif
}
