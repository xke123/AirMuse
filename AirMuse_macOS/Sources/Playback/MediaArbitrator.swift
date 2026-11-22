import Foundation
import Domain

// MARK: - MediaArbitrator

/// Arbitrates between multiple music playback providers.
/// Ported and modernized from AirMuse Windows MediaArbitrator.cpp.
/// Uses priority scoring and active-playback heuristics to select the best active provider.
public actor MediaArbitrator {

    public struct ProviderRegistration: Sendable {
        public let provider: any MusicPlaybackProvider
        public let basePriority: Int  // Higher = more preferred

        public init(provider: any MusicPlaybackProvider, basePriority: Int) {
            self.provider = provider
            self.basePriority = basePriority
        }
    }

    private var registrations: [String: ProviderRegistration] = [:]
    private var overrideProviderID: String?

    public init() {}

    // MARK: - Registration

    public func register(provider: any MusicPlaybackProvider, priority: Int = 10) {
        registrations[provider.providerID] = ProviderRegistration(provider: provider, basePriority: priority)
    }

    public func unregister(providerID: String) {
        registrations.removeValue(forKey: providerID)
        if overrideProviderID == providerID {
            overrideProviderID = nil
        }
    }

    public func setOverride(providerID: String?) {
        self.overrideProviderID = providerID
    }

    // MARK: - Arbitration

    /// Finds the currently best provider based on:
    /// 1. Manual user override (if set and available)
    /// 2. Provider with actively playing track (highest effective priority)
    /// 3. Highest base priority
    public func resolveBestProvider() async -> (any MusicPlaybackProvider)? {
        if let overrideID = overrideProviderID,
           let reg = registrations[overrideID] {
            return reg.provider
        }

        var candidates: [(provider: any MusicPlaybackProvider, score: Int)] = []

        for (_, reg) in registrations {
            let state = await reg.provider.getState()
            var score = reg.basePriority

            if state.isPlaying {
                score += 1000 // Actively playing provider has top priority
            } else if state.currentTrack != nil {
                score += 100  // Paused but has a track loaded
            }

            candidates.append((provider: reg.provider, score: score))
        }

        candidates.sort { $0.score > $1.score }
        return candidates.first?.provider
    }

    /// Resolves the aggregated best state across registered providers.
    public func resolveBestState() async -> PlaybackState {
        if let best = await resolveBestProvider() {
            return await best.getState()
        }
        return .idle
    }
}

