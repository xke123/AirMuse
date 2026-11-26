import Foundation
import WebKit
import Domain
import Infrastructure
import Playback
import Lyrics
import Providers

// MARK: - CompositionRoot

/// Central dependency assembly for AirMuse Core V2.
/// Replaces scattered `.shared` business singletons with explicit constructor injection.
@MainActor
public final class CompositionRoot {
    public let clock: any ClockProtocol
    public let httpClient: HTTPClient
    public let credentialVault: CredentialVault
    public let cacheDatabase: SQLiteDatabase
    public let sqlCacheStore: SQLiteCacheStore
    public let imageCache: ImageCacheV2
    public let playbackStore: PlaybackStore
    public let playbackSnapshotStore: PlaybackSnapshotStore
    public let playbackCoordinatorV2: PlaybackCoordinatorV2
    public let lyricsEngine: LyricsEngine
    public let lyricsRepository: LyricsRepositoryV2
    public let webRuntime: WebRuntime
    public let webEngine: AppleMusicWebEngine
    public let sessionCoordinator: SessionCoordinator
    public let webLoginController: WebLoginController
    public let appleMusicProvider: AppleMusicProvider

    public init(
        clock: any ClockProtocol = SystemClock(),
        transport: any HTTPTransportProtocol = URLSessionHTTPTransport(),
        secureStore: any SecureKeyValueStore = AppPrivateStore.shared,
        cacheDatabaseURL: URL? = nil
    ) {
        self.clock = clock
        let client = HTTPClient(transport: transport, clock: clock, maxConcurrentRequests: 6)
        self.httpClient = client
        let vault = CredentialVault(store: secureStore)
        self.credentialVault = vault

        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dbURL: URL = cacheDatabaseURL ?? cachesDir.appendingPathComponent("AirMuse/core_v2_cache.sqlite")
        self.cacheDatabase = SQLiteDatabase(dbURL: dbURL)
        let cacheStore = SQLiteCacheStore(dbURL: dbURL, clock: clock)
        self.sqlCacheStore = cacheStore
        self.imageCache = ImageCacheV2.shared

        let store = PlaybackStore()
        self.playbackStore = store
        let snapshotStore = PlaybackSnapshotStore()
        self.playbackSnapshotStore = snapshotStore

        let runtime = WebRuntime()
        self.webRuntime = runtime
        let engine = AppleMusicWebEngine(runtime: runtime, clock: clock) { ctx in
            let rec = try? await vault.load(providerID: ctx.providerID, accountID: ctx.accountID, kind: .user)
            return rec?.value
        }
        self.webEngine = engine
        self.playbackCoordinatorV2 = PlaybackCoordinatorV2(
            store: store,
            engine: engine,
            clock: clock,
            snapshotStore: snapshotStore
        )

        let authBackend = AmpSessionAuthBackend(ampClient: .shared)
        let coordinator = SessionCoordinator(
            providerID: "apple_music",
            vault: vault,
            backend: authBackend,
            clock: clock,
            onEngineIsolate: {
                await engine.isolateAndReset()
            },
            onClearWebSessionData: {
                await MainActor.run {
                    let ds = runtime.dataStore
                    Task {
                        let types = WKWebsiteDataStore.allWebsiteDataTypes()
                        let records = await ds.dataRecords(ofTypes: types)
                        await ds.removeData(ofTypes: types, for: records)
                    }
                }
            }
        )
        self.sessionCoordinator = coordinator
        self.webLoginController = WebLoginController(dataStore: runtime.dataStore, sessionCoordinator: coordinator)

        self.lyricsEngine = LyricsEngine(store: store)
        let lyricsDBURL = cachesDir.appendingPathComponent("AirMuse/lyrics_v2.sqlite")
        self.lyricsRepository = LyricsRepositoryV2(store: store, dbURL: lyricsDBURL)
        let libraryRepo = LibraryRepositoryV2(cache: cacheStore, sessionCoordinator: coordinator)
        self.appleMusicProvider = AppleMusicProvider(
            sessionAdapter: CoreV2SessionAdapter(sessionCoordinator: coordinator),
            libraryRepository: libraryRepo
        )
    }
}
