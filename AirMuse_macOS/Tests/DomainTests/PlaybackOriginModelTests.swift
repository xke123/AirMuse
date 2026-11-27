import Foundation
import Testing
@testable import Domain

@Suite("PlaybackOriginModelTests")
struct PlaybackOriginModelTests {

    @Test("P34: Legacy JSON without navigationTarget/stationContext and unknown enum kinds decode safely")
    func legacyAndUnknownDecoding() throws {
        let legacyJSON = """
        {
          "kind": "album",
          "sourceID": "alb-123",
          "sourceTitle": "Legacy Album",
          "isLibrary": false,
          "providerID": "apple_music"
        }
        """
        let decoded = try JSONDecoder().decode(PlaybackOrigin.self, from: Data(legacyJSON.utf8))
        #expect(decoded.kind == .album)
        #expect(decoded.sourceID == "alb-123")
        #expect(decoded.navigationTarget == nil)
        #expect(decoded.stationContext == nil)
        #expect(decoded.canNavigate == true)
        #expect(decoded.resolvedNavigationTarget == .resource(kind: .album, id: "alb-123", isLibrary: false, providerID: "apple_music"))

        let futureJSON = """
        {
          "kind": "future_kind_v9",
          "sourceID": "xyz",
          "sourceTitle": "Future",
          "isLibrary": true,
          "providerID": "apple_music",
          "navigationTarget": { "type": "future_route_v9", "id": "123" }
        }
        """
        let futureDecoded = try JSONDecoder().decode(PlaybackOrigin.self, from: Data(futureJSON.utf8))
        #expect(futureDecoded.kind == .unknown)
        #expect(futureDecoded.navigationTarget == .unknown)
        #expect(futureDecoded.canNavigate == false)
    }

    @Test("P34: Typed OriginNavigationTarget round-trips and stationContext avoids recursion")
    func typedRouteAndStationContextRoundTrip() throws {
        let seed = StationSeedResource(
            kind: .song,
            id: "song-1",
            title: "Seed Song",
            isLibrary: false,
            providerID: "apple_music",
            albumID: "alb-9",
            albumTitle: "Seed Album"
        )
        let ctx = StationOriginContext(
            stationID: "ra.999",
            stationType: .algorithmic,
            seedResource: seed,
            sourceNavigationTarget: .browseSection(id: "radio_am", title: "AM 电台")
        )
        let origin = PlaybackOrigin(
            kind: .station,
            sourceID: "ra.999",
            sourceTitle: "My Station",
            isLibrary: false,
            providerID: "apple_music",
            navigationTarget: .search(query: "周杰伦", scope: "catalog", sectionID: "songs"),
            stationContext: ctx
        )

        let data = try JSONEncoder().encode(origin)
        let decoded = try JSONDecoder().decode(PlaybackOrigin.self, from: data)
        #expect(decoded == origin)
        #expect(decoded.canNavigate == true)
        #expect(decoded.stationContext?.stationID == "ra.999")
        #expect(decoded.stationContext?.seedResource?.albumID == "alb-9")
    }
}
