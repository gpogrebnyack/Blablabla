import Foundation
import Darwin

/// Reads basic Mac hardware capabilities and recommends a cleanup mode.
/// All getters are cached after first read since none of this changes at runtime.
enum SystemAdvisor {
    static let shared = Snapshot()

    struct Snapshot {
        let chipName: String
        let physicalRAMGB: Double
        let freeDiskGB: Double
        let isAppleSilicon: Bool

        init() {
            self.chipName = Self.sysctlString("machdep.cpu.brand_string")
            self.physicalRAMGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            self.freeDiskGB = Self.freeDiskGB()
            #if arch(arm64)
            self.isAppleSilicon = true
            #else
            self.isAppleSilicon = false
            #endif
        }

        var formattedRAM: String { String(format: "%.0f GB", physicalRAMGB) }
        var formattedDisk: String { String(format: "%.1f GB free", freeDiskGB) }

        /// Recommend the best cleanup mode for this machine.
        /// Returns the recommended mode + a human-readable rationale.
        var recommendation: Recommendation {
            guard isAppleSilicon else {
                return .init(mode: .off,
                             tone: .warning,
                             message: "This Mac is not Apple Silicon. Full and Fast modes still work, but Full LLM relies on MLX which won't load.")
            }
            if physicalRAMGB < 8 {
                return .init(mode: .off,
                             tone: .warning,
                             message: "Only \(formattedRAM) of RAM. Stay on Off — the LLM (~5 GB resident) will swap heavily.")
            }
            if physicalRAMGB < 16 {
                return .init(mode: .fast,
                             tone: .info,
                             message: "\(formattedRAM) of RAM is fine for Off and Fast. Full will work but expect noticeable swap during long dictations.")
            }
            if freeDiskGB < 5 {
                return .init(mode: .fast,
                             tone: .warning,
                             message: "Only \(formattedDisk) free. Full mode needs to download ~2.4 GB. Free up space first.")
            }
            return .init(mode: .full,
                         tone: .ok,
                         message: "\(formattedRAM) of RAM, \(formattedDisk). Full LLM mode runs comfortably.")
        }

        // MARK: - Helpers

        private static func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            guard size > 0 else { return "Unknown" }
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buf, &size, nil, 0)
            return String(cString: buf)
        }

        private static func freeDiskGB() -> Double {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
            return Double(bytes) / 1_073_741_824
        }
    }

    struct Recommendation {
        let mode: CleanupMode
        let tone: Tone
        let message: String

        enum Tone { case ok, info, warning }
    }
}
