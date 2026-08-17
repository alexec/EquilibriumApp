import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The single place that answers "can this Mac run Apple's on-device LLM
/// right now?", and — when it can't — *why* not, so the UI can say something
/// more useful than "unavailable" and offer the right alternative.
///
/// Most Macs currently fall into one of the unavailable cases: anything
/// running macOS earlier than 26 has no FoundationModels framework at all,
/// Intel Macs are never eligible, and even eligible Macs report unavailable
/// until Apple Intelligence has been switched on and its model downloaded.
/// So every feature built on the model needs a non-LLM path, not just an
/// error message — see `WeeklyInsightGenerator.WeekHeaderStats.fallbackSentence`
/// and `WorkPreferencesForm`.
///
/// The framework doesn't exist in SDKs older than macOS 26 (e.g. the
/// Xcode 16.4 / macOS 15 SDK used by CI), so every reference to its types —
/// not just the `import` — is compiled out with `#if canImport(FoundationModels)`.
/// A `#available` guard alone isn't enough: that's a runtime check and doesn't
/// help the compiler resolve symbols missing from the SDK altogether.
enum OnDeviceModel {
    /// Why the on-device model can't be used. Deliberately coarser than
    /// FoundationModels' own reasons: the only distinction the UI cares
    /// about is whether this is permanent for this Mac or something the
    /// person could change.
    enum Unavailability: Equatable {
        /// macOS is older than 26, so the framework isn't there at all.
        case unsupportedOS
        /// Apple Intelligence doesn't run on this hardware (or in this
        /// region/language configuration).
        case deviceNotEligible
        /// Supported, but Apple Intelligence is switched off.
        case notEnabled
        /// Switched on, but the model is still downloading.
        case modelNotReady

        /// A short, matter-of-fact explanation for display. No apology and
        /// no call to action — the UI that shows this always offers the
        /// manual path right underneath it.
        var message: String {
            switch self {
            case .unsupportedOS:
                return "This Mac's version of macOS doesn't include Apple's on-device AI."
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .notEnabled:
                return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady:
                return "Apple Intelligence is still downloading its model."
            }
        }
    }

    /// Nil when the model is ready to use right now.
    ///
    /// Set `EQUILIBRIUM_NO_ON_DEVICE_MODEL=1` in the environment to force
    /// the unavailable path: the no-LLM UI is what most users will see, but
    /// it's invisible while developing on a Mac that has the model, and
    /// there's no other way to get at it short of turning off Apple
    /// Intelligence system-wide.
    static var unavailability: Unavailability? {
        if ProcessInfo.processInfo.environment["EQUILIBRIUM_NO_ON_DEVICE_MODEL"] == "1" {
            return .unsupportedOS
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            // Newer OSes may add reasons this build has never heard of;
            // treat them the same as "not for this Mac".
            @unknown default: return .deviceNotEligible
            }
        }
        #else
        return .unsupportedOS
        #endif
    }

    static var isAvailable: Bool { unavailability == nil }
}
