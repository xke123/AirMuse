import Foundation
import Testing
@testable import Domain
@testable import Playback
@testable import PlatformRuntime

// MARK: - Controlled Test Probe & Engines

private final class SharedAudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeCount: Int = 0
    private var _maxConcurrentAudio: Int = 0

    var activeCount: Int {
        lock.withLock { _activeCount }
    }
    var maxConcurrentAudio: Int {
        lock.withLock { _maxConcurrentAudio }
    }

    func markStarted() {
        lock.withLock {
            _activeCount += 1
            if _activeCount > _maxConcurrentAudio {
                _maxConcurrentAudio = _activeCount
            }
        }
    }

    func markStopped() {
        lock.withLock {
            _activeCount = max(0, _activeCount - 1)
        }
    }
}

private actor ControlledEngine: PlaybackEngineProtocol {
    let id = UUID()
    let probe: SharedAudioProbe
    var shouldFailPrepare: Bool = false
    var shouldFailStop: Bool = false
    private var isAudioActive: Bool = false
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    init(probe: SharedAudioProbe, shouldFailPrepare: Bool = false, shouldFailStop: Bool = false) {
        self.probe = probe
        self.shouldFailPrepare = shouldFailPrepare
        self.shouldFailStop = shouldFailStop
    }

    var engineInstanceID: UUID { id }

    func events() async -> AsyncStream<EngineEvent> {
        AsyncStream { c in
            let cid = UUID()
            continuations[cid] = c
        }
    }

    func emitLateEvent(context: PlaybackOperationContext, trackID: String) {
        for c in continuations.values {
            c.yield(.itemChanged(
                context: context,
                trackID: trackID,
                title: "Stale \(trackID)",
                artist: "Stale",
                albumTitle: "Stale",
                artworkURL: "",
                durationSeconds: 100
            ))
        }
    }

    func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {
        if shouldFailPrepare {
            throw CoreError.engineUnavailable("Simulated prepare failure")
        }
    }

    func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        switch command {
        case .playItem, .play:
            if !isAudioActive {
                isAudioActive = true
                probe.markStarted()
            }
            for c in continuations.values {
                c.yield(.stateChanged(context: context, status: .playing))
            }
        case .stop:
            if shouldFailStop {
                throw CoreError.handoffFailed("Simulated stop failure")
            }
            if isAudioActive {
                isAudioActive = false
                probe.markStopped()
            }
            for c in continuations.values {
                c.yield(.stateChanged(context: context, status: .idle))
            }
        default:
            break
        }
    }

    func isolateAndReset() async {
        if isAudioActive {
            isAudioActive = false
            probe.markStopped()
        }
    }
}

private final class ControlledAdapter: PlatformAdapter, @unchecked Sendable {
    let descriptor: PlatformDescriptor
    let engine: ControlledEngine
    var catalogProvider: (any MusicCatalogProvider)? { nil }
    var libraryProvider: (any MusicLibraryProvider)? { nil }
    var searchProvider: (any MusicSearchProvider)? { nil }
    var mutationProvider: (any MediaResourceMutationProvider)? { nil }
    var authProvider: (any MusicAuthenticationProvider)? { nil }
    var browseProvider: (any PlatformBrowseProvider)? { nil }
    var lyricsProvider: (any MusicLyricsProvider)? { nil }

    init(providerID: ProviderID, engine: ControlledEngine) {
        self.descriptor = PlatformDescriptor(
            providerID: providerID,
            displayName: providerID.rawValue,
            symbolName: "waveform",
            isAvailableInProduction: false,
            supportedBrowseTabs: [],
            capabilities: MusicProviderCapabilities()
        )
        self.engine = engine
    }

    func makePlaybackEngine() async -> (any PlaybackEngineProtocol)? {
        engine
    }
}

private final class ControlledFactory: PlatformAdapterFactory, @unchecked Sendable {
    let descriptor: PlatformDescriptor
    let adapter: ControlledAdapter

    init(providerID: ProviderID, engine: ControlledEngine) {
        self.adapter = ControlledAdapter(providerID: providerID, engine: engine)
        self.descriptor = adapter.descriptor
    }

    func makeAdapter() async -> any PlatformAdapter {
        adapter
    }
}

@Suite("PD07: EngineRouter Single Audio Ownership & Staged Handoff Tests (R30–R36, B10)")
struct EngineRouterTests {

    @Test("R30 & R31: Failed candidate prepare keeps active engine A playing; successful handoff keeps maxConcurrentAudio <= 1")
    func testSilentPrepareFailureAndSingleAudioHandoff() async throws {
        let probe = SharedAudioProbe()
        let engineA = ControlledEngine(probe: probe)
        let engineBFail = ControlledEngine(probe: probe, shouldFailPrepare: true)

        let registry = ProviderSessionRegistry()
        await registry.register(factory: ControlledFactory(providerID: ProviderID("prov_a"), engine: engineA))
        await registry.register(factory: ControlledFactory(providerID: ProviderID("prov_b"), engine: engineBFail))

        let router = EngineRouter(registry: registry)
        let sessionA = SessionContext(providerID: "prov_a", accountID: "a1", storefront: "us", sessionID: UUID(), generation: 1)
        let targetA = PlaybackTarget(kind: .song, providerResourceID: "s1", providerID: ProviderID("prov_a"), scope: .catalog(region: "us"))
        let idA = try await router.prepareCandidate(target: targetA, sessionContext: sessionA, deadlineSeconds: 5)
        try await router.activateCandidate(candidateEngineID: idA)
        try await router.execute(.playItem(id: "s1", kind: .song, startIndex: 0), context: PlaybackOperationContext(sessionID: sessionA.sessionID, engineInstanceID: idA, operationID: 1, trackID: "s1"))
        #expect(probe.activeCount == 1)

        // Prepare B fails -> A stays active and playing!
        let sessionB = SessionContext(providerID: "prov_b", accountID: "b1", storefront: "us", sessionID: UUID(), generation: 1)
        let targetB = PlaybackTarget(kind: .song, providerResourceID: "s2", providerID: ProviderID("prov_b"), scope: .catalog(region: "us"))
        do {
            _ = try await router.prepareCandidate(target: targetB, sessionContext: sessionB, deadlineSeconds: 5)
            Issue.record("Expected prepare B to fail")
        } catch CoreError.engineUnavailable {
            // Expected
        }
        #expect(probe.activeCount == 1)
        #expect(await router.engineInstanceID == idA)
        #expect(probe.maxConcurrentAudio == 1)
    }

    @Test("R32: Stop failure on active engine A blocks engine B activation with handoffFailed")
    func testStopFailureBlocksNewEngineActivation() async throws {
        let probe = SharedAudioProbe()
        let engineA = ControlledEngine(probe: probe, shouldFailStop: true)
        let engineB = ControlledEngine(probe: probe)

        let registry = ProviderSessionRegistry()
        await registry.register(factory: ControlledFactory(providerID: ProviderID("prov_a"), engine: engineA))
        await registry.register(factory: ControlledFactory(providerID: ProviderID("prov_b"), engine: engineB))

        let router = EngineRouter(registry: registry)
        let sessionA = SessionContext(providerID: "prov_a", accountID: "a1", storefront: "us", sessionID: UUID(), generation: 1)
        let idA = try await router.prepareCandidate(
            target: PlaybackTarget(kind: .song, providerResourceID: "s1", providerID: ProviderID("prov_a"), scope: .catalog(region: "us")),
            sessionContext: sessionA,
            deadlineSeconds: 5
        )
        try await router.activateCandidate(candidateEngineID: idA)
        try await router.execute(.playItem(id: "s1", kind: .song, startIndex: 0), context: PlaybackOperationContext(sessionID: sessionA.sessionID, engineInstanceID: idA, operationID: 1, trackID: "s1"))

        let sessionB = SessionContext(providerID: "prov_b", accountID: "b1", storefront: "us", sessionID: UUID(), generation: 1)
        let idB = try await router.prepareCandidate(
            target: PlaybackTarget(kind: .song, providerResourceID: "s2", providerID: ProviderID("prov_b"), scope: .catalog(region: "us")),
            sessionContext: sessionB,
            deadlineSeconds: 5
        )
        do {
            try await router.activateCandidate(candidateEngineID: idB)
            Issue.record("Expected handoffFailed when old engine stop fails")
        } catch CoreError.handoffFailed {
            // Expected
        }
        #expect(probe.maxConcurrentAudio == 1)
        #expect(await router.engineInstanceID == idA)
    }

    @Test("B10: switchRemoteToStagedLocal refuses to stage queue if stop fails")
    @MainActor
    func testStagedTransitionRefusesWhenStopFails() async throws {
        let probe = SharedAudioProbe()
        let engine = ControlledEngine(probe: probe, shouldFailStop: true)
        let store = PlaybackStore()
        let coordinator = PlaybackCoordinatorV2(store: store, engine: engine)

        let stationTrack = MusicTrack(id: "ra.1", title: "Live Radio", artistName: "Host", albumTitle: "", durationMs: 0, providerID: "fixture", providerTrackID: "ra.1")
        let stationOrigin = PlaybackOrigin(kind: .station, sourceID: "ra.1", sourceTitle: "Live Radio", providerID: "fixture")
        _ = try await coordinator.submitIntent(.replaceAndPlay, entries: [QueueEntry(track: stationTrack, origin: stationOrigin)], startIndex: 0, kind: .station)

        let localTrack = MusicTrack(id: "s.1", title: "Local Song", artistName: "Artist", albumTitle: "Album", durationMs: 180_000, providerID: "fixture", providerTrackID: "s.1")
        let localOrigin = PlaybackOrigin(kind: .album, sourceID: "alb.1", sourceTitle: "Album", providerID: "fixture")

        do {
            _ = try await coordinator.switchRemoteToStagedLocal(entries: [QueueEntry(track: localTrack, origin: localOrigin)])
            Issue.record("Expected handoffFailed when stop fails")
        } catch CoreError.handoffFailed {
            // Expected: queue must remain remoteEngine, not overwritten!
        }

        let snap = await coordinator.currentStructuredQueueSnapshot()
        #expect(snap.owner == .remoteEngine)
    }
}
