import Foundation
import Testing
import Domain
import Infrastructure
@testable import Providers

/// Opt-in live Apple Music AMP API verification suite for MAS04 / E01–E03.
/// Skipped during normal `swift test`; run with `AIRMUSE_LIVE_VERIFY=1 swift test --filter LiveAppleMusicVerificationTests`.
@Suite("LiveAppleMusicVerificationTests")
struct LiveAppleMusicVerificationTests {

    private func loadClient() async throws -> AppleMusicAmpClient? {
        guard ProcessInfo.processInfo.environment["AIRMUSE_LIVE_VERIFY"] == "1" else { return nil }
        let store = AppPrivateStore()
        let vault = CredentialVault(store: store)
        guard let lastAcc = try? await vault.load(providerID: "apple_music", accountID: "_last_active_", kind: .user),
              let userRec = try? await vault.load(providerID: "apple_music", accountID: lastAcc.value, kind: .user),
              !userRec.value.isEmpty else {
            return nil
        }
        let client = AppleMusicAmpClient(userToken: userRec.value)
        _ = try await client.ensureDeveloperToken()
        return client
    }

    @Test("MAS04 E01-E03: Production AppleMusicAmpClient library, rating, and station end-to-end verification")
    func testProductionAmpClientEndToEnd() async throws {
        guard let client = try await loadClient() else { return }

        // 1. Song station
        let songStation = try await client.fetchSongStation(songID: "268993333")
        #expect(songStation != nil)

        // 2. Artist detail rating (404 -> isRatingKnown == true, isFavorited == false) + artist station
        let artistDetail = try await client.fetchArtistDetail(artistID: "459885", isLibrary: false)
        #expect(artistDetail.isRatingKnown == true)
        let artistStation = try await client.fetchArtistStation(artistID: "459885")
        #expect(artistStation != nil)

        // 3. Reversible favorite PUT/DELETE on song
        let wasFav = try await client.fetchRating(resourceType: "songs", catalogID: "268993333")
        if !wasFav {
            let setTrue = try await client.setRating(resourceType: "songs", catalogID: "268993333", value: 1)
            #expect(setTrue == true)
            let setFalse = try await client.setRating(resourceType: "songs", catalogID: "268993333", value: nil)
            #expect(setFalse == false)
        }

        // 4. Reversible library add/readback/remove on test song
        let pre = try await client.fetchLibraryMembership(catalogID: "268993333", resourceType: "songs")
        if !pre.inLibrary {
            try await client.addToLibrary(catalogID: "268993333", resourceType: "songs")
            var resolvedLibID: String? = nil
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(700))
                let check = try await client.fetchLibraryMembership(catalogID: "268993333", resourceType: "songs")
                if check.inLibrary, let id = check.libraryID {
                    resolvedLibID = id
                    break
                }
            }
            #expect(resolvedLibID != nil)
            if let libID = resolvedLibID {
                try await client.removeFromLibrary(libraryID: libID, resourceType: "songs")
                try await Task.sleep(for: .milliseconds(700))
                let afterDel = try await client.fetchLibraryMembership(catalogID: "268993333", resourceType: "songs")
                #expect(afterDel.inLibrary == false)
            }
        }
    }
}
