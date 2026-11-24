import Foundation
import Domain
import Infrastructure

// MARK: - AppleMusicWebEngine

/// Core V2 playback engine bridging `PlaybackEngineProtocol` to `WebRuntime` (WKWebView + MusicKit JS).
/// Enforces total deadlines, typed JS arguments, instance/session/operation ID isolation,
/// and bounded crash recovery without ever mutating session state or falling back to 30s previews.
public actor AppleMusicWebEngine: PlaybackEngineProtocol {
    private let runtime: WebRuntime
    private let credentialProvider: @Sendable (SessionContext) async -> String?
    private let clock: any ClockProtocol

    private var activeSessionContext: SessionContext?
    private var activePlayContext: PlaybackOperationContext?
    private var lastLoggedStatus: PlaybackTransportStatus?
    private var lastLoggedItemKey: String?
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var crashRecoveryAttempts: Int = 0
    private let maxCrashRecoveries: Int = 2

    public init(
        runtime: WebRuntime,
        clock: any ClockProtocol = SystemClock(),
        credentialProvider: @escaping @Sendable (SessionContext) async -> String?
    ) {
        self.runtime = runtime
        self.clock = clock
        self.credentialProvider = credentialProvider

        Task { @MainActor [weak self, weak runtime] in
            guard let runtime else { return }
            runtime.onEvent = { [weak self] event in
                Task { await self?.handleInboundEvent(event) }
            }
            runtime.onProcessTerminated = { [weak self] crashedID in
                Task { await self?.handleProcessTerminated(crashedEngineID: crashedID) }
            }
        }
    }

    public var engineInstanceID: UUID {
        get async {
            await MainActor.run { runtime.engineInstanceID }
        }
    }

    public func events() async -> AsyncStream<EngineEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func prepare(sessionContext: SessionContext, deadlineSeconds: TimeInterval) async throws {
        activeSessionContext = sessionContext
        crashRecoveryAttempts = 0
        let storefront = sessionContext.storefront
        let eid = await engineInstanceID
        AppLogger.shared.log(
            category: .engine,
            level: .info,
            correlationID: "eng-\(eid.uuidString.prefix(6))",
            message: "准备 Web 播放引擎 (storefront=\(storefront), gen=\(sessionContext.generation), deadline=\(deadlineSeconds)s)"
        )

        await MainActor.run {
            runtime.loadIfNeeded(storefront: storefront)
        }
        try await runtime.waitUntilReady(deadlineSeconds: deadlineSeconds)

        if let token = await credentialProvider(sessionContext), !token.isEmpty {
            _ = try? await injectUserToken(token)
        }
    }

    public func execute(_ command: EngineCommand, context: PlaybackOperationContext) async throws {
        guard let session = activeSessionContext, session.sessionID == context.sessionID else {
            throw CoreError.staleSession
        }
        let currentEngineID = await engineInstanceID
        guard currentEngineID == context.engineInstanceID else {
            throw CoreError.staleSession
        }

        let corr = "eng-\(currentEngineID.uuidString.prefix(6))-op\(context.operationID)"

        switch command {
        case .playItem(let id, let kind, let startIndex):
            activePlayContext = context
            lastLoggedStatus = nil
            lastLoggedItemKey = nil
            AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "开始请求并加载曲目: \(kind) id=\(id) startIndex=\(startIndex)")
            let userToken = await credentialProvider(session) ?? ""
            let script = Self.playItemScript(kind: kind)
            let res = try await runtime.callBridgeScript(
                script,
                stringArgs: ["trackId": id, "uToken": userToken],
                numberArgs: ["startIndex": Double(startIndex), "opId": Double(context.operationID)]
            )
            if res.cancelled {
                AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "引擎播放指令已取消 (被新操作抢占)")
                throw CoreError.cancelled
            }
            if res.ok {
                AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "引擎播放指令启动成功: id=\(id)")
                return
            }
            let errMsg = res.error ?? "Unknown playback error"
            AppLogger.shared.log(category: .engine, level: .error, correlationID: corr, message: "引擎播放指令失败: \(errMsg)")
            if errMsg == "WEB_NOT_AUTHORIZED" {
                throw CoreError.userCredentialInvalid
            }
            throw CoreError.transport(statusCode: nil, message: errMsg)

        case .play:
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { await mk.play(); return true; } return false;"
            )

        case .pause:
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { mk.pause(); return true; } return false;"
            )

        case .stop:
            activePlayContext = nil
            lastLoggedStatus = nil
            lastLoggedItemKey = nil
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { mk.stop(); return true; } return false;"
            )

        case .seek(let seconds):
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { await mk.seekToTime(targetSec); return true; } return false;",
                numberArgs: ["targetSec": seconds]
            )

        case .setVolume(let volume):
            let clamped = Double(min(max(volume, 0), 1))
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { mk.volume = vol; return true; } return false;",
                numberArgs: ["vol": clamped]
            )

        case .skipNext:
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { await mk.skipToNextItem(); return true; } return false;"
            )

        case .skipPrevious:
            _ = try await runtime.callBridgeScript(
                "var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null; if (mk) { await mk.skipToPreviousItem(); return true; } return false;"
            )
        }
    }

    public func isolateAndReset() async {
        let oldID = await engineInstanceID
        AppLogger.shared.log(category: .engine, level: .info, correlationID: "eng-\(oldID.uuidString.prefix(6))", message: "隔离并重置 Web 播放引擎实例")
        activeSessionContext = nil
        activePlayContext = nil
        lastLoggedStatus = nil
        lastLoggedItemKey = nil
        await MainActor.run {
            runtime.isolateAndReset()
        }
    }

    // MARK: - Internal Helpers

    private func injectUserToken(_ token: String) async throws -> Bool {
        let js = """
        try {
            localStorage.setItem('media-user-token', uToken);
            localStorage.setItem('music.userToken', uToken);
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (mk && !mk.musicUserToken) { mk.musicUserToken = uToken; }
            return !!(mk && mk.isAuthorized);
        } catch(e) { return false; }
        """
        let res = try await runtime.callBridgeScript(js, stringArgs: ["uToken": token])
        return res.boolValue
    }

    private func handleInboundEvent(_ event: WebBridgeInboundEvent) async {
        let currentEngineID = await engineInstanceID
        switch event {
        case .ready(let eid, let isAuth):
            guard eid == currentEngineID else { return }
            emit(.readinessChanged(engineInstanceID: eid, isReady: true, isAuthorized: isAuth))

        case .playbackStateDidChange(let eid, let opID, let rawState, let isPlaying, let isBuffering, let isPaused):
            guard eid == currentEngineID, let op = activePlayContext else { return }
            if opID != 0 && opID != op.operationID { return }
            let status: PlaybackTransportStatus
            if isPlaying { status = .playing }
            else if isBuffering { status = .buffering }
            else if rawState == 6 { status = .seeking }
            else if isPaused { status = .paused }
            else { status = .idle }
            if lastLoggedStatus != status {
                lastLoggedStatus = status
                let corr = "eng-\(eid.uuidString.prefix(6))-op\(op.operationID)"
                switch status {
                case .buffering:
                    AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "正在缓冲音频流...")
                case .playing:
                    AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "音频播放开始")
                case .paused:
                    AppLogger.shared.log(category: .engine, level: .info, correlationID: corr, message: "播放已暂停")
                default:
                    break
                }
            }
            emit(.stateChanged(context: op, status: status))

        case .playbackTimeDidChange(let eid, let opID, let pos, let dur):
            guard eid == currentEngineID, let op = activePlayContext else { return }
            if opID != 0 && opID != op.operationID { return }
            emit(.positionUpdated(context: op, positionSeconds: pos, durationSeconds: dur))

        case .nowPlayingItemDidChange(let eid, let opID, let title, let artist, let album, let artURL, let trackID, _, let pbDur, let metaDur):
            guard eid == currentEngineID, let op = activePlayContext else { return }
            if opID != 0 && opID != op.operationID { return }
            let dur = pbDur > 0 ? pbDur : metaDur
            let itemKey = "\(trackID)|\(title)|\(artist)"
            if !title.isEmpty && lastLoggedItemKey != itemKey {
                lastLoggedItemKey = itemKey
                AppLogger.shared.log(
                    category: .engine,
                    level: .info,
                    correlationID: "eng-\(eid.uuidString.prefix(6))-op\(op.operationID)",
                    message: "曲目信息更新: \(title) - \(artist) (id=\(trackID), dur=\(String(format: "%.1f", dur))s)"
                )
            }
            emit(.itemChanged(
                context: op,
                trackID: trackID,
                title: title,
                artist: artist,
                albumTitle: album,
                artworkURL: artURL,
                durationSeconds: dur
            ))

        case .playbackEnded(let eid, let opID, let pos, let dur):
            guard eid == currentEngineID, let op = activePlayContext else { return }
            if opID != 0 && opID != op.operationID { return }
            AppLogger.shared.log(
                category: .engine,
                level: .info,
                correlationID: "eng-\(eid.uuidString.prefix(6))-op\(op.operationID)",
                message: "曲目播放结束: id=\(op.trackID) (pos=\(String(format: "%.1f", pos))s / dur=\(String(format: "%.1f", dur))s)"
            )
            emit(.trackEnded(context: op, positionSeconds: pos, durationSeconds: dur))
        }
    }

    private func handleProcessTerminated(crashedEngineID: UUID) async {
        AppLogger.shared.log(
            category: .engine,
            level: .warn,
            correlationID: "eng-\(crashedEngineID.uuidString.prefix(6))",
            message: "WebContent 进程异常终止，启动有界恢复 (attempt=\(crashRecoveryAttempts + 1)/\(maxCrashRecoveries))"
        )
        emit(.crashed(engineInstanceID: crashedEngineID, reason: "WebContent process terminated"))
        guard crashRecoveryAttempts < maxCrashRecoveries, let session = activeSessionContext else {
            return
        }
        crashRecoveryAttempts += 1
        let delayMs = Int64(crashRecoveryAttempts * 500)
        try? await clock.sleep(for: .milliseconds(delayMs))
        try? await prepare(sessionContext: session, deadlineSeconds: 10.0)
    }

    private func emit(_ event: EngineEvent) {
        for cont in continuations.values {
            cont.yield(event)
        }
    }

    private static func playItemScript(kind: PlayableKind) -> String {
        let queueExpr: String = switch kind {
        case .song:
            "var cleanId = String(trackId).replace(/^[ilpa]\\./, ''); try { await mk.setQueue({ song: cleanId }); } catch(e1) { await mk.setQueue({ song: String(trackId) }); }"
        case .album:
            "var cleanId = String(trackId).replace(/^[ilp]\\./, ''); await mk.setQueue({ album: cleanId, startWith: startIndex });"
        case .playlist:
            "var cleanId = String(trackId).replace(/^[ilp]\\./, ''); await mk.setQueue({ playlist: cleanId, startWith: startIndex });"
        case .station:
            "await mk.setQueue({ station: String(trackId) });"
        }

        return """
        try {
            window.__airmuseOpId = opId;
            window.__airmuseTransitioning = true;
            var mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) { window.__airmuseTransitioning = false; return { ok: false, error: 'MusicKit not loaded' }; }
            if (uToken && !mk.musicUserToken) { mk.musicUserToken = uToken; }
            if (!mk.isAuthorized) { window.__airmuseTransitioning = false; return { ok: false, error: 'WEB_NOT_AUTHORIZED' }; }
            if (mk.isPlaying) { try { mk.stop(); } catch(e) {} }
            \(queueExpr)
            if (window.__airmuseOpId !== opId) { return { ok: false, cancelled: true }; }
            window.__airmuseTransitioning = false;
            await Promise.race([Promise.resolve(mk.play()), new Promise(function(r) { setTimeout(r, 1500); })]);
            return { ok: true };
        } catch(e) {
            window.__airmuseTransitioning = false;
            return { ok: false, error: String(e && e.message ? e.message : e) };
        }
        """
    }
}
