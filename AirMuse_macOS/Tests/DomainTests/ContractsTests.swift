import Foundation
import Testing
@testable import Domain

private struct UnimplementedLibraryProvider: MusicLibraryProvider {
    let providerID: String = "fixture"
    func fetchLibrary() async throws -> MusicLibrary {
        MusicLibrary(tracks: [], albums: [], artists: [], playlists: [])
    }
}

private struct UnimplementedCatalogProvider: MusicCatalogProvider {
    let providerID: String = "fixture"
    func searchCatalog(query: String, limit: Int) async throws -> MusicSearchResult {
        MusicSearchResult(tracks: [], albums: [], artists: [], playlists: [])
    }
}

@Suite("PD02: Contracts, Capabilities & PageCursor Tests (R09–R12, B11–B14)")
struct ContractsTests {

    @Test("R09 & R10: Unimplemented library/catalog methods throw unsupported instead of fake success or empty arrays")
    func testUnsupportedMethodsThrowInsteadOfFakeSuccess() async {
        func expectUnsupported(_ block: () async throws -> Void) async {
            do {
                try await block()
                Issue.record("Expected MusicProviderError.unsupported")
            } catch MusicProviderError.unsupported {
                // expected
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let lib = UnimplementedLibraryProvider()
        await expectUnsupported { try await lib.addTrackToLibrary(trackID: "s-1") }
        await expectUnsupported { try await lib.removeTrackFromLibrary(trackID: "s-1") }
        await expectUnsupported { _ = try await lib.isTrackInLibrary(trackID: "s-1") }

        let cat = UnimplementedCatalogProvider()
        await expectUnsupported { _ = try await cat.fetchAlbumTracks(albumID: "a-1") }
        await expectUnsupported { _ = try await cat.fetchFeaturedPlaylists() }
    }

    @Test("R11 & R12: PageCursor is opaque, non-URL, and rejects cross-provider or cross-scope reuse")
    func testPageCursorIsolation() {
        let cursor = PageCursor(
            opaqueToken: "page_2_opaque_token",
            providerID: ProviderID("fixture"),
            scope: .library(accountID: "acct-1", region: "us"),
            routeFingerprint: "playlist:pl-1"
        )
        #expect(cursor.matches(
            providerID: ProviderID("fixture"),
            scope: .library(accountID: "acct-1", region: "us"),
            routeFingerprint: "playlist:pl-1"
        ))
        #expect(!cursor.matches(
            providerID: .appleMusic,
            scope: .library(accountID: "acct-1", region: "us"),
            routeFingerprint: "playlist:pl-1"
        ))
        #expect(!cursor.matches(
            providerID: ProviderID("fixture"),
            scope: .library(accountID: "acct-2", region: "us"),
            routeFingerprint: "playlist:pl-1"
        ))
        #expect(!cursor.matches(
            providerID: ProviderID("fixture"),
            scope: .library(accountID: "acct-1", region: "us"),
            routeFingerprint: "playlist:pl-2"
        ))
    }

    @Test("B11 & B12: QueueCapabilities resolves conservatively from engine evidence")
    func testConservativeCapabilityResolution() {
        let unverifiedAlgo = QueueCapabilities.resolve(
            owner: .remoteEngine,
            stationKind: .algorithmic,
            evidence: nil
        )
        #expect(!unverifiedAlgo.canSeek)
        #expect(!unverifiedAlgo.canSkipNext)
        #expect(!unverifiedAlgo.canPause)

        let verifiedAlgo = QueueCapabilities.resolve(
            owner: .remoteEngine,
            stationKind: .algorithmic,
            evidence: EngineCapabilityEvidence(canPause: true, canSeek: true, canSkipNext: true, canSkipPrevious: false)
        )
        #expect(verifiedAlgo.canSeek)
        #expect(verifiedAlgo.canSkipNext)
        #expect(verifiedAlgo.canPause)
    }

    @Test("CoreError includes normalized cursor, handoff, and engine errors")
    func testNormalizedCoreErrors() {
        let errors: [CoreError] = [
            .invalidCursor,
            .superseded,
            .outcomeUnknown("timeout"),
            .engineUnavailable("no engine"),
            .handoffFailed("stop failed")
        ]
        #expect(errors.count == 5)
    }
}
