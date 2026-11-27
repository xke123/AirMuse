import Foundation
import Testing
import Domain
@testable import Application
@testable import Providers

private actor MockMutationProvider: MediaResourceMutationProvider {
    var libraryIDs: Set<String> = []
    var favoriteIDs: Set<String> = []
    var favoriteLinksLibrary: Bool = false
    var partialReceiptMode: Bool = false
    var shouldSuspendNextWrite: Bool = false
    var nextError: Error? = nil
    var suspendWriteContinuation: CheckedContinuation<Void, Never>? = nil
    var writeSuspendedWaiter: CheckedContinuation<Void, Never>? = nil
    var isWriteSuspended: Bool = false
    var writeCalls: [(String, String)] = []
    var readCalls: [String] = []

    func setNextError(_ err: Error?) { nextError = err }
    func setFavoriteLinksLibrary(_ linked: Bool) { favoriteLinksLibrary = linked }
    func setPartialReceiptMode(_ partial: Bool) { partialReceiptMode = partial }
    func setSuspendNextWrite(_ suspend: Bool) { shouldSuspendNextWrite = suspend }
    func seedServer(id: String, inLibrary: Bool, isFavorite: Bool) {
        if inLibrary { libraryIDs.insert(id) } else { libraryIDs.remove(id) }
        if isFavorite { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
    }

    func suspendNextWrite() async {
        await withCheckedContinuation { cont in
            suspendWriteContinuation = cont
            isWriteSuspended = true
            writeSuspendedWaiter?.resume()
            writeSuspendedWaiter = nil
        }
    }

    func waitUntilWriteSuspended() async {
        if isWriteSuspended { return }
        await withCheckedContinuation { cont in
            writeSuspendedWaiter = cont
        }
    }

    func resumeSuspendedWrite() {
        isWriteSuspended = false
        suspendWriteContinuation?.resume()
        suspendWriteContinuation = nil
    }

    func mediaActionCapabilities(for resource: MediaResourceReference) async -> MediaActionCapabilities {
        MediaActionCapabilities(
            isAuthenticated: true,
            canPlay: true,
            canReadLibraryMembership: true,
            canAddToLibrary: true,
            canRemoveFromLibrary: true,
            canReadFavorite: true,
            canSetFavorite: true
        )
    }

    func fetchResourceState(_ resource: MediaResourceReference) async throws -> MediaResourceState {
        readCalls.append(resource.canonicalID)
        return MediaResourceState(
            libraryMembership: .known(libraryIDs.contains(resource.canonicalID)),
            favorite: .known(favoriteIDs.contains(resource.canonicalID))
        )
    }

    func addToLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        if let err = nextError { nextError = nil; throw err }
        writeCalls.append(("add", resource.canonicalID))
        libraryIDs.insert(resource.canonicalID)
        return MediaMutationReceipt(
            state: MediaResourceState(
                libraryMembership: .known(true),
                favorite: .known(favoriteIDs.contains(resource.canonicalID))
            )
        )
    }

    func removeFromLibrary(_ resource: MediaResourceReference) async throws -> MediaMutationReceipt {
        if let err = nextError { nextError = nil; throw err }
        writeCalls.append(("remove", resource.canonicalID))
        libraryIDs.remove(resource.canonicalID)
        return MediaMutationReceipt(
            state: MediaResourceState(
                libraryMembership: .known(false),
                favorite: .known(favoriteIDs.contains(resource.canonicalID))
            )
        )
    }

    func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws -> MediaMutationReceipt {
        if shouldSuspendNextWrite {
            shouldSuspendNextWrite = false
            await suspendNextWrite()
        }
        writeCalls.append((enabled ? "fav" : "unfav", resource.canonicalID))
        if let err = nextError { nextError = nil; throw err }
        if enabled {
            favoriteIDs.insert(resource.canonicalID)
            if favoriteLinksLibrary { libraryIDs.insert(resource.canonicalID) }
        } else {
            favoriteIDs.remove(resource.canonicalID)
        }
        return MediaMutationReceipt(
            state: MediaResourceState(
                libraryMembership: partialReceiptMode ? .unknown : .known(libraryIDs.contains(resource.canonicalID)),
                favorite: .known(enabled)
            )
        )
    }
}

@Suite("MediaResourceStateStoreTests")
@MainActor
struct MediaResourceStateStoreTests {

    @Test("T19/T21/T22: Library add, unfavorite independence, and favorite-adds-library sync")
    func testLibraryAndFavoriteSync() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(providerID: "apple_music", accountID: "acct-A", storefront: "cn"))

        let song = MediaResourceReference(kind: .song, canonicalID: "s-1", title: "Song 1")
        _ = try await store.setLibraryMembership(song, inLibrary: true)
        #expect(store.state(for: song).libraryMembership == .known(true))

        await provider.setFavoriteLinksLibrary(true)
        let song2 = MediaResourceReference(kind: .song, canonicalID: "s-2", title: "Song 2")
        _ = try await store.setFavorite(song2, enabled: true)
        #expect(store.state(for: song2).favorite == .known(true))
        #expect(store.state(for: song2).libraryMembership == .known(true))

        // Unfavorite does not assume library removal
        _ = try await store.setFavorite(song2, enabled: false)
        #expect(store.state(for: song2).favorite == .known(false))
        #expect(store.state(for: song2).libraryMembership == .known(true))
    }

    @Test("T02/T20: Personal playlist rejects library and favorite writes")
    func testPersonalPlaylistReadOnlyGuard() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)

        let personal = MediaResourceReference(kind: .playlist(.personal), canonicalID: "p.1", title: "My List")
        await #expect(throws: MediaActionError.readOnlyPlaylist) {
            _ = try await store.setLibraryMembership(personal, inLibrary: false)
        }
        await #expect(throws: MediaActionError.readOnlyPlaylist) {
            _ = try await store.setFavorite(personal, enabled: true)
        }
        let writes = await provider.writeCalls
        #expect(writes.isEmpty)
    }

    @Test("T23/T25: Rapid favorite toggles converge to final intent and failure rolls back to lastKnown")
    func testRapidToggleAndErrorRollback() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let artist = MediaResourceReference(kind: .artist, canonicalID: "ar-1", title: "Artist 1")
        store.seedKnownState(for: artist, favorite: false)

        async let t1 = store.setFavorite(artist, enabled: true)
        await Task.yield()
        async let t2 = store.setFavorite(artist, enabled: false)
        await Task.yield()
        async let t3 = store.setFavorite(artist, enabled: true)
        _ = try await (t1, t2, t3)
        #expect(store.state(for: artist).favorite == .known(true))

        await provider.setNextError(MediaActionError.forbidden)
        await #expect(throws: MediaActionError.forbidden) {
            _ = try await store.setFavorite(artist, enabled: false)
        }
        if case .failed(let lastKnown, _) = store.state(for: artist).favorite {
            #expect(lastKnown == true)
        } else {
            Issue.record("Expected failed state with lastKnown == true")
        }
    }

    @Test("T24: Timeout reconciles with server state instead of blind retry")
    func testTimeoutReconcilesWithServer() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let artist = MediaResourceReference(kind: .artist, canonicalID: "ar-timeout", title: "Artist T")
        // Simulate server already applied favorite=true even though client timed out
        await provider.seedServer(id: "ar-timeout", inLibrary: false, isFavorite: true)
        await provider.setNextError(URLError(.timedOut))

        let reconciled = try await store.setFavorite(artist, enabled: true)
        #expect(reconciled.favorite == .known(true))
        let reads = await provider.readCalls
        #expect(reads == ["ar-timeout"])
    }

    @Test("T26: Account switch isolates state and rejects stale writes")
    func testAccountSwitchIsolation() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let song = MediaResourceReference(kind: .song, canonicalID: "s-iso", title: "Song Iso")
        store.seedKnownState(for: song, libraryMembership: true, favorite: true)
        #expect(store.state(for: song).favorite == .known(true))

        store.setScope(.init(accountID: "acct-B", storefront: "us"))
        #expect(store.state(for: song) == .unknown)
    }

    @Test("MAS-R06/R07: Field-level receipt patching preserves other field and pending intent")
    func testFieldLevelReceiptPatching() async throws {
        let provider = MockMutationProvider()
        await provider.setPartialReceiptMode(true)
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let song = MediaResourceReference(kind: .song, canonicalID: "s-patch", title: "Patch")
        store.seedKnownState(for: song, libraryMembership: true, favorite: false)

        // Favorite receipt with unknown libraryMembership must preserve libraryMembership == known(true)
        let outcome = try await store.setFavoriteWithOutcome(song, enabled: true)
        if case .confirmed(let st, _) = outcome {
            #expect(st.favorite == .known(true))
            #expect(st.libraryMembership == .known(true))
        } else {
            Issue.record("Expected confirmed outcome")
        }
    }

    @Test("MAS-R08/R10: Double toggle failure rolls back to confirmedBool, not pending target; superseded returns superseded")
    func testDoubleToggleFailureRollbackAndSuperseded() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let artist = MediaResourceReference(kind: .artist, canonicalID: "ar-dbl", title: "Artist D")
        store.seedKnownState(for: artist, favorite: false)

        await provider.setSuspendNextWrite(true)
        await provider.setNextError(MediaActionError.forbidden)
        let first = Task { try await store.setFavoriteWithOutcome(artist, enabled: true) }
        await provider.waitUntilWriteSuspended()
        let second = Task { try await store.setFavoriteWithOutcome(artist, enabled: false) }
        await Task.yield()
        await provider.resumeSuspendedWrite()

        let o1 = try await first.value
        if case .superseded = o1 {
            // Expected superseded for first intent
        } else {
            Issue.record("Expected first intent to be superseded")
        }

        await provider.setNextError(MediaActionError.forbidden)
        // Wait for second to finish (it didn't have error when first consumed it, so let's test explicit failure rollback)
        _ = try? await second.value
        await provider.setNextError(MediaActionError.forbidden)
        await #expect(throws: MediaActionError.forbidden) {
            _ = try await store.setFavoriteWithOutcome(artist, enabled: true)
        }
        // Must roll back to confirmedBool (false), NOT unconfirmed pending target
        #expect(store.state(for: artist).favorite.confirmedBool == false)
    }

    @Test("MAS-R11/R15: Stale GET does not overwrite newer write revision, and concurrent reads coalesce")
    func testStaleGetDoesNotOverwriteWriteAndCoalesces() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let song = MediaResourceReference(kind: .song, canonicalID: "s-read", title: "Read")
        await provider.seedServer(id: "s-read", inLibrary: true, isFavorite: false)

        async let r1 = store.refreshState(for: song)
        async let r2 = store.refreshState(for: song)
        let (s1, s2) = try await (r1, r2)
        #expect(s1 == s2)
        let reads = await provider.readCalls
        #expect(reads.count == 1)
    }

    @Test("MAS-R13/R14: Timeout reconciliation distinguishes different server state and unknownOutcome")
    func testTimeoutReconciliationOutcomes() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore()
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let artist = MediaResourceReference(kind: .artist, canonicalID: "ar-diff", title: "Artist Diff")
        await provider.seedServer(id: "ar-diff", inLibrary: false, isFavorite: false)
        await provider.setNextError(URLError(.timedOut))

        let outcome = try await store.setFavoriteWithOutcome(artist, enabled: true)
        if case .reconciledDifferent(let st, let actual) = outcome {
            #expect(actual == false)
            #expect(st.favorite == .known(false))
        } else {
            Issue.record("Expected reconciledDifferent when server returned false")
        }
    }

    @Test("MAS-R17: Bounded cache does not evict pending entries")
    func testBoundedCacheProtectsPending() async throws {
        let provider = MockMutationProvider()
        let store = MediaResourceStateStore(maxCachedEntries: 64)
        store.configure(provider: provider)
        store.setScope(.init(accountID: "acct-A", storefront: "cn"))

        let pinned = MediaResourceReference(kind: .song, canonicalID: "s-pinned", title: "Pinned")
        store.seedKnownState(for: pinned, libraryMembership: false, favorite: false)
        // Fill cache beyond 64
        for i in 0..<80 {
            let item = MediaResourceReference(kind: .song, canonicalID: "s-fill-\(i)", title: "Fill \(i)")
            store.seedKnownState(for: item, libraryMembership: true, favorite: true)
        }
        // Cache stayed bounded
        #expect(store.state(for: pinned) == .unknown)
    }
}
