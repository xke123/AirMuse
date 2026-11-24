import Foundation
import Domain

// MARK: - PlaybackCoordinator

/// Actor that owns the active playback provider and arbitrates between
/// multiple provider implementations.
///
/// Lifecycle:
///   1. `start()` – begins polling / observation tasks.
///   2. `stop()`  – cancels all tasks (called on app termination).
public actor PlaybackCoordinator {

    // MARK: - Injected dependencies

    private let store: PlaybackStore

    // MARK: - Registered providers

    private var providers: [String: any MusicPlaybackProvider] = [:]
    private var activeProviderID: String?
    private var currentQueue: PlaybackQueue = PlaybackQueue()
    private var lastSkipTime: Date?
    private var playGeneration: Int = 0

    // MARK: - Task handles

    private var tasks: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    public init(store: PlaybackStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    public func start() async {
        // Initial state is idle until a provider is activated.
        await store.update(state: .idle)
    }

    public func shutdown() async {
        for (_, task) in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    // MARK: - Provider management

    public func register(provider: any MusicPlaybackProvider) {
        providers[provider.providerID] = provider
    }

    public func activate(providerID: String) async throws {
        guard let provider = providers[providerID] else {
            throw CoordinatorError.unknownProvider(providerID)
        }
        // Cancel observation task for previously active provider.
        if let old = activeProviderID {
            tasks[old]?.cancel()
            tasks.removeValue(forKey: old)
        }
        activeProviderID = providerID

        // Fetch initial state.
        let initial = await provider.getState()
        await store.update(state: initial)

        // Start observation loop.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.observeProvider(provider)
        }
        tasks[providerID] = task
    }

    // MARK: - Transport commands

    public func play() async throws {
        try await activeProvider().play()
    }

    public func pause() async throws {
        try await activeProvider().pause()
    }

    public func playPause() async throws {
        let state = await store.state
        if state.isPlaying {
            try await pause()
        } else {
            try await play()
        }
    }

    public func stop() async throws {
        try await activeProvider().stop()
    }

    public func skipToNext() async throws {
        let now = Date()
        if let last = lastSkipTime, now.timeIntervalSince(last) < 0.35 {
            return
        }
        lastSkipTime = now

        if let next = currentQueue.nextTrack {
            currentQueue.advance()
            try await playTrack(next, in: currentQueue)
        } else {
            try await activeProvider().skipToNext()
        }
    }

    public func skipToPrevious() async throws {
        if let prev = currentQueue.previousTrack {
            currentQueue.retreat()
            try await playTrack(prev, in: currentQueue)
        } else {
            try await activeProvider().skipToPrevious()
        }
    }

    public func seek(toMs ms: Int64) async throws {
        try await activeProvider().seek(toMs: ms)
        var s = await store.state
        s.positionMs = ms
        s.timestampDate = .now
        await store.update(state: s)
    }

    public func setVolume(_ volume: Float) async throws {
        try await activeProvider().setVolume(volume)
    }

    public func playTrack(_ track: MusicTrack, in queue: PlaybackQueue) async throws {
        playGeneration += 1
        let myGen = playGeneration
        self.currentQueue = queue
        let targetProviderID = track.providerID.isEmpty ? "apple_music" : track.providerID

        // Optimistic UI update: immediately show track info & loading bar and trigger parallel lyrics/artwork fetch
        let prevState = await store.state
        let optimisticState = PlaybackState(
            status: .loading,
            isPlaying: false,
            positionMs: 0,
            durationMs: track.durationMs,
            volume: prevState.volume,
            isMuted: prevState.isMuted,
            repeatMode: prevState.repeatMode,
            shuffleEnabled: prevState.shuffleEnabled,
            currentTrack: track,
            providerID: targetProviderID,
            sourceName: targetProviderID == "apple_music" ? "Apple Music" : targetProviderID,
            artworkData: nil,
            timestampDate: .now
        )
        await store.update(state: optimisticState)

        if activeProviderID == nil || activeProviderID != targetProviderID {
            try? await activate(providerID: targetProviderID)
        }
        guard myGen == playGeneration else { return }

        let p = try activeProvider()
        do {
            try await p.playTrack(track, in: queue)
        } catch {
            if myGen == playGeneration {
                var failed = await store.state
                failed.status = .failed
                failed.isPlaying = false
                failed.errorMessage = error.localizedDescription
                await store.update(state: failed)
            }
            throw error
        }
        guard myGen == playGeneration else { return }

        var state = await p.getState()
        if state.durationMs == 0 && track.durationMs > 0 {
            state.durationMs = track.durationMs
        }
        if !state.isPlaying && state.positionMs == 0 && state.status == .paused {
            state.status = .loading
        }
        state.currentTrack = track
        await store.update(state: state)
    }

    // MARK: - Private helpers

    private func activeProvider() throws -> any MusicPlaybackProvider {
        if let id = activeProviderID, let p = providers[id] {
            return p
        }
        if let defaultProvider = providers["apple_music"] ?? providers.values.first {
            return defaultProvider
        }
        throw CoordinatorError.noActiveProvider
    }

    /// Polling loop – bridges non-streaming providers to the store.
    private func observeProvider(_ provider: any MusicPlaybackProvider) async {
        if let stream = await provider.stateUpdates() {
            for await state in stream {
                if Task.isCancelled { break }
                await store.update(state: state)
            }
            return
        }
        while !Task.isCancelled {
            let state = await provider.getState()
            await store.update(state: state)
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: - Errors

    public enum CoordinatorError: Error, Sendable {
        case noActiveProvider
        case unknownProvider(String)
    }
}
