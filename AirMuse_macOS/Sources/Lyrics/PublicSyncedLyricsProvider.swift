import Foundation
import Domain
import Infrastructure

// MARK: - PublicSyncedLyricsProvider

/// Generic third-party synced lyrics fallback provider (LRCLIB + NetEase).
/// Decoupled from AppleMusicProvider so any platform track can resolve lyrics
/// without linking Apple Music adapter.
public actor PublicSyncedLyricsProvider: MusicLyricsProvider {
    public let providerID: String = "public_lyrics"

    public init() {}

    public func fetchLyrics(for track: MusicTrack) async throws -> LyricsDocument? {
        if let doc = await fetchLRCLIBLyrics(track: track) {
            return doc
        }
        if let doc = await fetchNetEaseLyrics(track: track) {
            return doc
        }
        return nil
    }

    private func fetchLRCLIBLyrics(track: MusicTrack) async -> LyricsDocument? {
        guard !track.title.isEmpty else { return nil }
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        var queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artistName)
        ]
        if !track.albumTitle.isEmpty {
            queryItems.append(URLQueryItem(name: "album_name", value: track.albumTitle))
        }
        if track.durationMs > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(Int(track.durationMs / 1000))"))
        }
        comps?.queryItems = queryItems
        guard let url = comps?.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("AirMuse/2.0 (macOS)", forHTTPHeaderField: "User-Agent")

        AppLogger.shared.log(category: .network, level: .debug, message: "发起 LRCLIB 歌词请求: \(url.absoluteString)")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let synced = json["syncedLyrics"] as? String, !synced.isEmpty else {
            return nil
        }

        let lines = Self.parseLRC(synced)
        return lines.isEmpty ? nil : LyricsDocument(trackKey: track.trackKey, lines: lines, statusText: "歌词同步中")
    }

    private func fetchNetEaseLyrics(track: MusicTrack) async -> LyricsDocument? {
        guard let titleEnc = track.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let artistEnc = track.artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        let searchURLStr = "https://music.163.com/api/search/get/web?s=\(titleEnc)%20\(artistEnc)&type=1&limit=1"
        guard let searchURL = URL(string: searchURLStr) else { return nil }

        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 4.0
        searchReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        searchReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        AppLogger.shared.log(category: .network, level: .debug, message: "发起网易云歌词搜索请求: \(track.title)")
        guard let (sData, sResp) = try? await URLSession.shared.data(for: searchReq),
              let sHttp = sResp as? HTTPURLResponse, sHttp.statusCode == 200,
              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
              let result = sJson["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              let firstSong = songs.first,
              let songId = firstSong["id"] as? Int else {
            return nil
        }

        let lyricURLStr = "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1"
        guard let lyricURL = URL(string: lyricURLStr) else { return nil }

        var lyricReq = URLRequest(url: lyricURL)
        lyricReq.timeoutInterval = 4.0
        lyricReq.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        lyricReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        guard let (lData, lResp) = try? await URLSession.shared.data(for: lyricReq),
              let lHttp = lResp as? HTTPURLResponse, lHttp.statusCode == 200,
              let lJson = try? JSONSerialization.jsonObject(with: lData) as? [String: Any],
              let lrcObj = lJson["lrc"] as? [String: Any],
              let lyricText = lrcObj["lyric"] as? String, !lyricText.isEmpty else {
            return nil
        }

        var lines = Self.parseLRC(lyricText)
        if let tlyricObj = lJson["tlyric"] as? [String: Any],
           let tlyricText = tlyricObj["lyric"] as? String, !tlyricText.isEmpty {
            let tLines = Self.parseLRC(tlyricText)
            for tLine in tLines {
                if let idx = lines.firstIndex(where: { abs($0.timeMs - tLine.timeMs) < 500 }) {
                    lines[idx].translation = tLine.text
                }
            }
        }
        return lines.isEmpty ? nil : LyricsDocument(trackKey: track.trackKey, lines: lines, statusText: "歌词同步中")
    }

    static func parseLRC(_ raw: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        let lrcRegex = try? NSRegularExpression(pattern: #"^\[(\d{2}):(\d{2}(?:\.\d+)?)\](.*)$"#)
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = lrcRegex else { continue }
            let ns = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))
            if let match = matches.first, match.numberOfRanges >= 4 {
                let min = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: match.range(at: 2))) ?? 0
                let rawText = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
                let text = unescapeXMLEntities(rawText)
                let ms = Int64((min * 60.0 + sec) * 1000.0)
                if !text.isEmpty {
                    lines.append(LyricsLine(timeMs: ms, text: text))
                }
            }
        }
        lines.sort(by: { $0.timeMs < $1.timeMs })
        return lines
    }

    private static func unescapeXMLEntities(_ str: String) -> String {
        str.replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
