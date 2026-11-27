import Foundation

// MARK: - MediaActionResolver

/// Pure, deterministic resolver that builds menu descriptors and play menus
/// from typed resource, location, capabilities, state, and current detail context.
public enum MediaActionResolver {

    /// Resolves the pure internal navigation menu for the bottom Origin Capsule.
    /// Always shows the three fixed options (Go to Origin, View Album, View Artist) and never emits
    /// playback, queue mutation, or platform write actions.
    public static func resolveOriginMenu(
        for entry: QueueEntry,
        owner: QueueOwner,
        currentDetail: MediaDetailIdentity?
    ) -> MediaActionMenuDescriptor {
        var originActions: [MediaAction] = []
        var trackActions: [MediaAction] = []

        let origin = entry.origin
        if origin.canNavigate {
            originActions.append(.navigateToOriginConcise(origin))
        } else {
            originActions.append(.originStatusPlaceholder(title: "前往来源（未知）"))
        }

        if owner == .remoteEngine, let seed = origin.stationContext?.seedResource {
            switch seed.kind {
            case .artist:
                if !seed.id.isEmpty {
                    originActions.append(.navigateToSeedArtist(MediaArtistRef(id: seed.id, name: seed.title, isLibrary: seed.isLibrary)))
                }
            case .song:
                if let albumID = seed.albumID, !albumID.isEmpty {
                    originActions.append(.navigateToSeedAlbum(id: albumID, title: seed.albumTitle ?? "种子专辑", isLibrary: seed.isLibrary))
                }
            case .album:
                if !seed.id.isEmpty {
                    originActions.append(.navigateToSeedAlbum(id: seed.id, title: seed.title, isLibrary: seed.isLibrary))
                }
            default:
                break
            }
        }

        let track = entry.track
        let isLib = track.isLibrary || track.id.hasPrefix("i.")
        if let albumID = track.albumID, !albumID.isEmpty {
            trackActions.append(.navigateToAlbum(id: albumID, title: track.albumTitle.isEmpty ? "专辑" : track.albumTitle, isLibrary: isLib))
        } else {
            trackActions.append(.originStatusPlaceholder(title: "查看专辑（未知）"))
        }

        var seenArtistIDs = Set<String>()
        var artistRefs: [MediaArtistRef] = []
        for artist in track.artists where !artist.id.isEmpty && seenArtistIDs.insert(artist.id).inserted {
            artistRefs.append(artist)
        }
        if artistRefs.count == 1 {
            trackActions.append(.navigateToArtist(artistRefs[0]))
        } else if artistRefs.count > 1 {
            trackActions.append(.navigateToArtistsSubmenu(artistRefs))
        } else {
            trackActions.append(.originStatusPlaceholder(title: "查看歌手（未知）"))
        }

        _ = currentDetail
        return MediaActionMenuDescriptor(sections: [
            MediaActionMenuSection(actions: originActions),
            MediaActionMenuSection(actions: trackActions)
        ])
    }

    /// Resolves the page Play Capsule menu items for a resource.
    /// - Returns: Grouped sections for the Play Capsule (`[replace, shuffle]` and `[interrupt, prepend, append]`, or `[listen]` for station).
    public static func resolvePlayMenu(for context: MediaActionContext) -> MediaActionMenuDescriptor {
        guard context.capabilities.canPlay else {
            return MediaActionMenuDescriptor(sections: [])
        }
        switch context.resource.kind {
        case .station:
            return MediaActionMenuDescriptor(sections: [
                MediaActionMenuSection(actions: [
                    .play(intent: .replaceAndPlay, title: "收听", symbolName: "play.fill", isCollectionDefault: false)
                ])
            ])

        case .song, .queueEntry:
            return MediaActionMenuDescriptor(sections: [
                MediaActionMenuSection(actions: [
                    .play(intent: .replaceAndPlay, title: "仅播放此歌曲", symbolName: "play.fill", isCollectionDefault: false)
                ]),
                MediaActionMenuSection(actions: [
                    .play(intent: .interruptAndPlay, title: "立即插播", symbolName: "bolt.fill", isCollectionDefault: false),
                    .play(intent: .prepend, title: "加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false),
                    .play(intent: .append, title: "加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false)
                ])
            ])

        case .album, .playlist:
            return MediaActionMenuDescriptor(sections: [
                MediaActionMenuSection(actions: [
                    .play(intent: .replaceAndPlay, title: "播放", symbolName: "play.fill", isCollectionDefault: true),
                    .play(intent: .shuffleAndPlay, title: "随机播放", symbolName: "shuffle", isCollectionDefault: true)
                ]),
                MediaActionMenuSection(actions: [
                    .play(intent: .interruptAndPlay, title: "立即插播", symbolName: "bolt.fill", isCollectionDefault: false),
                    .play(intent: .prepend, title: "加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false),
                    .play(intent: .append, title: "加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false)
                ])
            ])

        case .artist:
            return MediaActionMenuDescriptor(sections: [
                MediaActionMenuSection(actions: [
                    .play(intent: .replaceAndPlay, title: "播放热门歌曲", symbolName: "play.fill", isCollectionDefault: true),
                    .play(intent: .shuffleAndPlay, title: "随机播放热门歌曲", symbolName: "shuffle", isCollectionDefault: true)
                ]),
                MediaActionMenuSection(actions: [
                    .play(intent: .interruptAndPlay, title: "立即插播热门歌曲", symbolName: "bolt.fill", isCollectionDefault: false),
                    .play(intent: .prepend, title: "热门歌曲加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false),
                    .play(intent: .append, title: "热门歌曲加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false)
                ])
            ])
        }
    }

    /// Resolves the full context menu descriptor (NSMenu) for any resource/location.
    /// Group order: Playback/Queue -> Library & Favorite -> Navigation & Radio -> Queue Remove.
    public static func resolveContextMenu(for context: MediaActionContext) -> MediaActionMenuDescriptor {
        let playbackSection = resolvePlaybackSection(for: context)
        let platformSection = context.selectedCount > 1 ? MediaActionMenuSection(actions: []) : resolvePlatformSection(for: context)
        let navigationSection = context.selectedCount > 1 ? MediaActionMenuSection(actions: []) : resolveNavigationSection(for: context)
        let queueRemoveSection = resolveQueueRemoveSection(for: context)

        return MediaActionMenuDescriptor(sections: [
            playbackSection,
            platformSection,
            navigationSection,
            queueRemoveSection
        ])
    }

    // MARK: - Section Builders

    private static func resolvePlaybackSection(for context: MediaActionContext) -> MediaActionMenuSection {
        guard context.capabilities.canPlay else {
            return MediaActionMenuSection(actions: [])
        }
        let resource = context.resource

        if resource.kind == .queueEntry {
            var actions: [MediaAction] = []
            if let entryID = resource.queueEntryID {
                actions.append(.playQueueEntry(entryID: entryID))
            }
            let targetIDs = context.selectedQueueEntryIDs.isEmpty
                ? (resource.queueEntryID.map { [$0] } ?? [])
                : context.selectedQueueEntryIDs
            if !targetIDs.isEmpty && context.capabilities.canReorderQueue {
                actions.append(.moveQueueEntryToNext(entryIDs: targetIDs))
                actions.append(.moveQueueEntryToEnd(entryIDs: targetIDs))
            }
            return MediaActionMenuSection(actions: actions)
        }

        if resource.kind == .station {
            return MediaActionMenuSection(actions: [
                .play(intent: .replaceAndPlay, title: "收听", symbolName: "play.fill", isCollectionDefault: false)
            ])
        }

        if resource.kind == .song {
            let suffix = context.selectedCount > 1 ? " (\(context.selectedCount) 首)" : ""
            var actions: [MediaAction] = [
                .play(
                    intent: .replaceAndPlay,
                    title: context.selectedCount > 1 ? "播放所选\(suffix)" : "仅播放此歌曲",
                    symbolName: "play.fill",
                    isCollectionDefault: false
                )
            ]
            if context.selectedCount > 1 {
                actions.append(.play(intent: .shuffleAndPlay, title: "随机播放所选\(suffix)", symbolName: "shuffle", isCollectionDefault: true))
            }
            actions.append(.play(intent: .interruptAndPlay, title: "立即插播", symbolName: "bolt.fill", isCollectionDefault: false))
            actions.append(.play(intent: .prepend, title: "加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false))
            actions.append(.play(intent: .append, title: "加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false))
            return MediaActionMenuSection(actions: actions)
        }

        if resource.kind == .artist {
            return MediaActionMenuSection(actions: [
                .play(intent: .replaceAndPlay, title: "播放热门歌曲", symbolName: "play.fill", isCollectionDefault: true),
                .play(intent: .shuffleAndPlay, title: "随机播放热门歌曲", symbolName: "shuffle", isCollectionDefault: true),
                .play(intent: .interruptAndPlay, title: "立即插播热门歌曲", symbolName: "bolt.fill", isCollectionDefault: false),
                .play(intent: .prepend, title: "热门歌曲加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false),
                .play(intent: .append, title: "热门歌曲加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false)
            ])
        }

        // Album / Playlist
        return MediaActionMenuSection(actions: [
            .play(intent: .replaceAndPlay, title: "播放", symbolName: "play.fill", isCollectionDefault: true),
            .play(intent: .shuffleAndPlay, title: "随机播放", symbolName: "shuffle", isCollectionDefault: true),
            .play(intent: .interruptAndPlay, title: "立即插播", symbolName: "bolt.fill", isCollectionDefault: false),
            .play(intent: .prepend, title: "加入队列开头", symbolName: "text.line.first.and.arrowtriangle.forward", isCollectionDefault: false),
            .play(intent: .append, title: "加入队列末尾", symbolName: "text.badge.plus", isCollectionDefault: false)
        ])
    }

    private static func resolvePlatformSection(for context: MediaActionContext) -> MediaActionMenuSection {
        let caps = context.capabilities
        guard caps.isAuthenticated else {
            return MediaActionMenuSection(actions: [])
        }
        let resource = context.resource
        var actions: [MediaAction] = []

        // Library membership
        let supportsLibraryWrite: Bool
        switch resource.kind {
        case .song, .queueEntry, .album:
            supportsLibraryWrite = true
        case .playlist(let ownership):
            // Personal, collaborative, and unknown playlists are strictly read-only containers.
            supportsLibraryWrite = ownership.isContainerWritable
        case .artist, .station:
            supportsLibraryWrite = false
        }

        if supportsLibraryWrite {
            switch context.state.libraryMembership {
            case .unknown:
                if caps.canReadLibraryMembership && (caps.canAddToLibrary || caps.canRemoveFromLibrary) {
                    actions.append(.libraryStatusPlaceholder(title: "资料库状态查询中…"))
                }
            case .pending:
                actions.append(.libraryStatusPlaceholder(title: "资料库状态同步中…"))
            case .known(let inLibrary):
                if inLibrary && caps.canRemoveFromLibrary {
                    actions.append(.removeFromLibrary(resource))
                } else if !inLibrary && caps.canAddToLibrary {
                    actions.append(.addToLibrary(resource))
                }
            case .failed(let lastKnown, _):
                if let lastKnown {
                    if lastKnown && caps.canRemoveFromLibrary {
                        actions.append(.removeFromLibrary(resource))
                    } else if !lastKnown && caps.canAddToLibrary {
                        actions.append(.addToLibrary(resource))
                    }
                } else if caps.canReadLibraryMembership && (caps.canAddToLibrary || caps.canRemoveFromLibrary) {
                    actions.append(.libraryStatusPlaceholder(title: "资料库状态未知"))
                }
            }
        }

        // Favorite
        let supportsFavoriteWrite: Bool
        switch resource.kind {
        case .song, .queueEntry, .album, .artist:
            supportsFavoriteWrite = true
        case .playlist(let ownership):
            supportsFavoriteWrite = ownership.isContainerWritable
        case .station:
            supportsFavoriteWrite = false
        }

        if supportsFavoriteWrite && caps.canSetFavorite {
            switch context.state.favorite {
            case .unknown:
                if caps.canReadFavorite {
                    actions.append(.favoriteStatusPlaceholder(title: "收藏状态查询中…"))
                }
            case .pending:
                actions.append(.favoriteStatusPlaceholder(title: "收藏状态同步中…"))
            case .known(let isFav):
                actions.append(isFav ? .unfavorite(resource) : .favorite(resource))
            case .failed(let lastKnown, _):
                if let lastKnown {
                    actions.append(lastKnown ? .unfavorite(resource) : .favorite(resource))
                } else if caps.canReadFavorite {
                    actions.append(.favoriteStatusPlaceholder(title: "收藏状态未知"))
                }
            }
        }

        return MediaActionMenuSection(actions: actions)
    }

    private static func resolveNavigationSection(for context: MediaActionContext) -> MediaActionMenuSection {
        let resource = context.resource
        let currentDetail = context.currentDetail
        var actions: [MediaAction] = []

        switch resource.kind {
        case .song:
            if context.capabilities.canStartSongStation {
                actions.append(.startSongStation(resource))
            }
            if let albumID = resource.albumID, !albumID.isEmpty,
               currentDetail != .album(id: albumID) {
                actions.append(.navigateToAlbum(id: albumID, title: resource.albumTitle ?? "专辑", isLibrary: resource.isLibrary))
            }
            appendArtistNavigation(artists: resource.artists, currentDetail: currentDetail, into: &actions)

        case .queueEntry:
            var originAlbumID: String?
            var originArtistID: String?
            if let origin = resource.origin, origin.canNavigate {
                let isSameDetail: Bool
                switch (origin.kind, origin.sourceID, currentDetail) {
                case (.album, let sid?, .album(let cid)): isSameDetail = (sid == cid)
                case (.playlist, let sid?, .playlist(let cid)): isSameDetail = (sid == cid)
                case (.artist, let sid?, .artist(let cid)): isSameDetail = (sid == cid)
                default: isSameDetail = false
                }
                if !isSameDetail {
                    actions.append(.navigateToOrigin(origin))
                }
                if origin.kind == .album { originAlbumID = origin.sourceID }
                if origin.kind == .artist { originArtistID = origin.sourceID }
            }
            if let albumID = resource.albumID, !albumID.isEmpty,
               currentDetail != .album(id: albumID),
               albumID != originAlbumID {
                actions.append(.navigateToAlbum(id: albumID, title: resource.albumTitle ?? "专辑", isLibrary: resource.isLibrary))
            }
            appendArtistNavigation(artists: resource.artists, currentDetail: currentDetail, excludingArtistID: originArtistID, into: &actions)

        case .album:
            if currentDetail != .album(id: resource.canonicalID) {
                actions.append(.navigateToAlbum(id: resource.canonicalID, title: resource.title, isLibrary: resource.isLibrary))
            }
            appendArtistNavigation(artists: resource.artists, currentDetail: currentDetail, into: &actions)

        case .playlist:
            if currentDetail != .playlist(id: resource.canonicalID) {
                actions.append(.navigateToPlaylist(id: resource.canonicalID, title: resource.title, isLibrary: resource.isLibrary))
            }

        case .artist:
            if context.capabilities.canStartArtistStation {
                let ref = MediaArtistRef(id: resource.canonicalID, name: resource.title, isLibrary: resource.isLibrary)
                actions.append(.startArtistStation(ref))
            }
            if currentDetail != .artist(id: resource.canonicalID) {
                let ref = MediaArtistRef(id: resource.canonicalID, name: resource.title, isLibrary: resource.isLibrary)
                actions.append(.navigateToArtist(ref))
            }

        case .station:
            if resource.hasStationDetail, currentDetail != .station(id: resource.canonicalID) {
                actions.append(.navigateToStationDetail(id: resource.canonicalID, title: resource.title))
            }
        }

        return MediaActionMenuSection(actions: actions)
    }

    private static func resolveQueueRemoveSection(for context: MediaActionContext) -> MediaActionMenuSection {
        guard context.resource.kind == .queueEntry, context.capabilities.canRemoveFromQueue else {
            return MediaActionMenuSection(actions: [])
        }
        let targetIDs = context.selectedQueueEntryIDs.isEmpty
            ? (context.resource.queueEntryID.map { [$0] } ?? [])
            : context.selectedQueueEntryIDs
        guard !targetIDs.isEmpty else {
            return MediaActionMenuSection(actions: [])
        }
        return MediaActionMenuSection(actions: [.removeQueueEntries(entryIDs: targetIDs)])
    }

    private static func appendArtistNavigation(
        artists: [MediaArtistRef],
        currentDetail: MediaDetailIdentity?,
        excludingArtistID: String? = nil,
        into actions: inout [MediaAction]
    ) {
        var seenIDs = Set<String>()
        var filtered: [MediaArtistRef] = []
        for artist in artists {
            guard !artist.id.isEmpty,
                  artist.id != excludingArtistID,
                  currentDetail != .artist(id: artist.id),
                  seenIDs.insert(artist.id).inserted else { continue }
            filtered.append(artist)
        }
        if filtered.count == 1 {
            actions.append(.navigateToArtist(filtered[0]))
        } else if filtered.count > 1 {
            actions.append(.navigateToArtistsSubmenu(filtered))
        }
    }
}
