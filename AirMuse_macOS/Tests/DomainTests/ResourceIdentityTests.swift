import Foundation
import Testing
@testable import Domain

@Suite("PD01: Unified ResourceIdentity & Scope Tests (R04–R07, B06–B08, B21)")
struct ResourceIdentityTests {

    @Test("R04: Same kind and opaqueID across different providers are not equal")
    func testCrossProviderIdentityCollisionPrevention() {
        let appleSong = ResourceIdentity(
            providerID: .appleMusic,
            kind: .song,
            opaqueID: "song-100",
            scope: .catalog(region: "cn")
        )
        let fixtureSong = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .song,
            opaqueID: "song-100",
            scope: .catalog(region: "cn")
        )
        #expect(appleSong != fixtureSong)
        #expect(appleSong.scopedKey != fixtureSong.scopedKey)

        let detailA = MediaDetailIdentity.resource(appleSong)
        let detailB = MediaDetailIdentity.resource(fixtureSong)
        #expect(detailA != detailB)
    }

    @Test("R05: Different accounts, regions, and catalog vs library scopes are distinct")
    func testScopeIsolation() {
        let catCN = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .album,
            opaqueID: "alb-1",
            scope: .catalog(region: "cn")
        )
        let catUS = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .album,
            opaqueID: "alb-1",
            scope: .catalog(region: "us")
        )
        let libA = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .album,
            opaqueID: "alb-1",
            scope: .library(accountID: "acct-a", region: "cn")
        )
        let libB = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .album,
            opaqueID: "alb-1",
            scope: .library(accountID: "acct-b", region: "cn")
        )
        #expect(catCN != catUS)
        #expect(catCN != libA)
        #expect(libA != libB)
        #expect(Set([catCN, catUS, libA, libB]).count == 4)
    }

    @Test("R07: Unknown provider or unknown scope is invalid and never defaults to Apple Music")
    func testUnknownProviderAndScopeNotDefaultedToAppleMusic() throws {
        let unknownIdentity = ResourceIdentity(
            providerID: .unknown,
            kind: .song,
            opaqueID: "s-1",
            scope: .catalog(region: "us")
        )
        #expect(!unknownIdentity.isValid)

        let unknownScope = ResourceIdentity(
            providerID: ProviderID("fixture"),
            kind: .song,
            opaqueID: "s-1",
            scope: .unknown
        )
        #expect(!unknownScope.isValid)

        #expect(PlaybackOrigin.unknown.providerID == ProviderID.unknown.rawValue)
        #expect(!PlaybackOrigin.unknown.canNavigate)

        let legacyOriginWithoutProvider = """
        {"kind":"album","sourceID":"alb-1","isLibrary":false}
        """.data(using: .utf8)!
        let decodedOrigin = try JSONDecoder().decode(PlaybackOrigin.self, from: legacyOriginWithoutProvider)
        #expect(decodedOrigin.providerID == ProviderID.unknown.rawValue)
        #expect(decodedOrigin.resolvedNavigationTarget == nil)

        let navWithoutProvider = """
        {"type":"resource","kind":"album","id":"alb-1","isLibrary":false}
        """.data(using: .utf8)!
        let decodedNav = try JSONDecoder().decode(OriginNavigationTarget.self, from: navWithoutProvider)
        #expect(!decodedNav.isNavigable)
    }

    @Test("B08: Non-Apple Music track with i. prefix is NOT inferred as library")
    func testNoPrefixInferenceInDomain() {
        let fixtureTrack = MusicTrack(
            id: "i.fixture-1",
            title: "Indie Song",
            artistName: "Indie Artist",
            albumTitle: "Indie Album",
            durationMs: 120_000,
            providerID: "fixture",
            providerTrackID: "i.fixture-1"
        )
        #expect(!fixtureTrack.isLibrary)
        #expect(fixtureTrack.libraryID == nil)
        #expect(fixtureTrack.catalogID == "i.fixture-1")

        let ref = MediaResourceReference.from(track: fixtureTrack)
        #expect(!ref.isLibrary)
        #expect(ref.providerID == "fixture")
        #expect(ref.catalogID == "i.fixture-1")
    }

    @Test("B21: PlaybackTarget binds explicit providerID and scope")
    func testPlaybackTargetIdentityBinding() {
        let target = PlaybackTarget(
            kind: .station,
            providerResourceID: "st-1",
            providerID: ProviderID("fixture"),
            scope: .catalog(region: "jp"),
            title: "Fixture Radio",
            storefront: "jp"
        )
        #expect(target.providerID == ProviderID("fixture"))
        #expect(target.scope == .catalog(region: "jp"))
        #expect(target.identity?.opaqueID == "st-1")
    }
}
