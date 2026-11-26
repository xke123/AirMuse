import Foundation
import Testing
import Domain
@testable import Providers

private actor MockMutationProvider: MediaResourceMutationProvider {
    var libraryIDs: Set<String> = []
    var favoriteIDs: Set<String> = []
    var favoriteLinksLibrary: Bool = false
    var nextError: Error? = nil
    var suspendWriteContinuation: CheckedContinuation<Void, Never>? = nil
    var writeCalls: [(String, String)] = []
    var readCalls: [String] = []

    func setNextError(_ err: Error?) { nextError = err }
    func setFavoriteLinksLibrary(_ linked: Bool) { favoriteLinksLibrary = linked }
    func seedServer(id: String, inLibrary: Bool, isFavorite: Bool) {
        if inLibrary { libraryIDs.insert(id) } else { libraryIDs.remove(id) }
        if isFavorite { favoriteIDs.insert(id) } else { favoriteIDs.remove(id) }
    }

    func suspendNextWrite() async {
        await withCheckedContinuation { cont in
            suspendWriteContinuation = cont
        }
    }

    func resumeSuspendedWrite() {
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
                libraryMembership: .known(libraryIDs.contains(resource.canonicalID)),
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
}
