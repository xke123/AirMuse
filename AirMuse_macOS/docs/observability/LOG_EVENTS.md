# LOG — 全量事件字典
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

事件为实施契约，非当前日志已存在的声明。共 21 个域；逐事件建立生产发射点与测试映射。各域 context 是适用时必需；不适用明确 absent，禁止合成业务 ID；字段中的 error/outcome/trace 等使用 CONTRACTS。禁止 raw payload。高频事件可聚合，关键状态/拒绝/终态不采样。每个 begin 或 requested 所属操作必须有明确 terminal，即便对应完成事件复用通用 outcome。

## APP
责任模块：AppLifecycleCoordinator / CompositionRoot / AppDelegate。上下文：`runID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `app.launch.begin` | `launchReason,build,commit` | 启动入口 |
| `app.environment.detected` | `os,arch,sdk,displayRefreshHz` | 实测环境/unknown |
| `app.configuration.loaded` | `theme,logMode,settingsRevision` | 配置加载 |
| `app.service.initialized` | `service,durationMs,outcome` | 每个服务 |
| `app.stage.ready` | `windowRef,durationMs` | 宿主可交互 |
| `app.first_frame` | `measurementSource,durationMs` | 仅真实首帧证据 |
| `app.warmup.begin` | `service,policy` | 预热开始 |
| `app.warmup.completed` | `service,outcome,durationMs` | 预热结束 |
| `app.sleep` | `reason` | 睡眠 |
| `app.wake` | `recoveryPolicy` | 唤醒 |
| `app.memory_pressure` | `level,action` | 压力与释放 |
| `app.shutdown.begin` | `reason` | 退出 |
| `app.shutdown.completed` | `releasedCount,flushOutcome` | 退出结果 |

## PLATFORM
责任模块：ProviderSessionRegistry / ApplicationServices。上下文：`providerID,sessionGeneration`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `platform.registered` | `descriptorRef,capabilities` | 注册不激活 |
| `platform.registration.rejected` | `reasonCode` | 重复或无效 |
| `platform.activation.requested` | `activationRef,reason` | 按需激活 |
| `platform.activation.reused` | `activationRef,adapterRef` | 复用/合并 |
| `platform.activation.completed` | `activationRef,adapterRef,durationMs` | 实际创建 |
| `platform.activation.failed` | `activationRef,error` | 失败 |
| `platform.browse.changed` | `previousProvider,nextProvider,routeRef` | 浏览变更 |
| `platform.playback.changed` | `previousProvider,nextProvider,leaseRef` | 已确认播放路由 |
| `platform.operation.routed` | `operation,resourceRef,operationProviderID,browsingProviderID,playingProviderID` | 目标路由 |
| `platform.capabilities.changed` | `before,after,evidence` | 有效能力 |
| `platform.deactivated` | `reason,adapterRef` | 停用 |
| `platform.resources.released` | `resourceType,count,outcome` | 释放 |

## SESSION
责任模块：SessionCoordinator / ProviderSessionRegistry / AccountService。上下文：`providerID,accountRef,sessionID,sessionGeneration`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `session.restore.begin` | `hasStoredSession` | 恢复 |
| `session.restore.completed` | `outcome,authorizationState` | 恢复结果 |
| `session.state.changed` | `before,after,reasonCode` | 状态转换 |
| `session.generation.changed` | `previousGeneration,nextGeneration` | 会话隔离 |
| `session.snapshot.published` | `snapshotRevision,subscriberCount` | 发布 |
| `session.account.changed` | `previousAccountRef,nextAccountRef` | 切换 |
| `session.invalidated` | `reasonCode` | 失效 |
| `session.stale_result.discarded` | `receivedGeneration,expectedGeneration,reasonCode` | 过期 |
| `session.scope.changed` | `previousScopeRef,nextScopeRef` | 缓存/状态域 |
| `session.shutdown.completed` | `outcome` | 清理 |

## AUTH
责任模块：AccountService / AppleMusicIntegrationUI / SessionCoordinator / CredentialVault。上下文：`providerID,sessionID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `auth.login.begin` | `method` | 登录 |
| `auth.web.navigation` | `hostClass,stage` | 无URL原文 |
| `auth.callback.received` | `sourceClass,validationResult` | 无code |
| `auth.credential.detected` | `credentialKind,present` | 不记录长度或内容 |
| `auth.credential.verified` | `credentialKind,outcome,expiryState` | 校验 |
| `auth.credential.expired` | `credentialKind,reasonCode` | 失效 |
| `auth.authorization.changed` | `before,after,evidence` | 订阅/权限 |
| `auth.refresh.begin` | `reasonCode` | 刷新 |
| `auth.refresh.completed` | `outcome,durationMs` | 结束 |
| `auth.login.completed` | `outcome` | 登录终态 |
| `auth.logout.begin` | `accountRef` | 退出 |
| `auth.logout.completed` | `credentialClearOutcome,cacheClearOutcome,engineOutcome` | 退出终态 |

## HTTP
责任模块：HTTPClient / AppleMusicAmpClient / independent lyrics transport。上下文：`requestID,providerID,attempt`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `http.request.created` | `method,endpointTemplate,timeoutMs` | 逻辑请求 |
| `http.request.queued` | `pool,queueDepth` | 排队 |
| `http.request.started` | `queueWaitMs,deadlineMs` | 实际传输 |
| `http.request.coalesced` | `ownerRequestID,consumerCount` | 请求合并 |
| `http.response.received` | `statusCode,responseBytes,durationMs` | 传输结果 |
| `http.response.parsed` | `itemCount,missingFieldCounts,parseMs` | 解析 |
| `http.request.retry_scheduled` | `reasonCode,backoffMs,nextAttempt` | 重试 |
| `http.request.timeout` | `stage,deadlineMs` | 超时 |
| `http.request.cancelled` | `reasonCode,initiator` | 取消 |
| `http.request.failed` | `error,retryable` | 失败 |
| `http.response.discarded` | `reasonCode,expectedGeneration,actualGeneration` | 过期 |
| `http.request.completed` | `outcome,attemptCount,durationMs` | 逻辑终态 |
| `http.metrics.collected` | `dnsMs,tcpMs,tlsMs,ttfbMs,source` | 仅可获得的指标 |
| `api.rate_limited` | `scopeRef,retryAfterMs` | 限流 |
| `api.authorization_failed` | `statusCode,classification` | 401/403 |
| `api.schema_mismatch` | `schemaRef,missingFields` | 结构错误 |

## BROWSE
责任模块：BrowseService / SearchCollectionService / AppleMusicAdapter / LibraryWindowController。上下文：`providerID,routeRef,browseGeneration`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `browse.page.requested` | `scopeRef,routeKind` | 请求 |
| `browse.page.loaded` | `sectionCount,itemCount,cacheStatus` | 响应 |
| `browse.page.rendered` | `renderedCount,viewRevision` | 实际渲染 |
| `browse.page.cancelled` | `reasonCode` | 取消 |
| `browse.page.discarded` | `expectedGeneration,actualGeneration` | 过期 |
| `browse.section.resolved` | `sectionRef,kind,capabilities` | 栏目 |
| `browse.section.page.completed` | `cursorRef,itemCount,hasNext` | 栏目分页 |
| `collection.detail.requested` | `resourceRef,resourceKind` | 详情 |
| `collection.detail.loaded` | `itemCount,totalCount,hasNext` | 详情结果 |
| `collection.detail.failed` | `error` | 失败 |
| `search.requested` | `queryRef,scopeRef` | 搜索 |
| `search.debounced` | `suppressedCount,delayMs` | 防抖 |
| `search.completed` | `countsByKind,outcome` | 搜索终态 |
| `search.result.discarded` | `reasonCode,expectedGeneration,actualGeneration` | 过期 |
| `search.pagination.completed` | `cursorRef,itemCount,totalLoaded` | 搜索分页 |
| `library.category.changed` | `previousRouteRef,nextRouteRef` | 分类 |

## RESOURCE
责任模块：AppleMusicAdapter / SearchCollectionService / MediaActionResolver。上下文：`providerID,resourceRef,resourceKind,scopeRef`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `resource.identity.resolved` | `identitySource,hasCatalogID,hasLibraryID` | 真实身份 |
| `resource.identity.invalid` | `reasonCode` | 无效 |
| `resource.mapping.resolved` | `catalogRef,libraryRef,evidence` | 映射 |
| `resource.mapping.failed` | `reasonCode` | 失败 |
| `resource.relationship.requested` | `itemSequence,requestedKinds` | 关系查询 |
| `resource.relationship.resolved` | `albumRef,artistRefs,outcome` | 实际关系 |
| `resource.relationship.discarded` | `reasonCode,itemSequence` | 过期 |
| `resource.ownership.resolved` | `ownership,evidence` | 歌单所有权 |
| `resource.permission.denied` | `action,reasonCode` | 权限 |
| `resource.capability.unavailable` | `capability,reasonCode` | 不可用 |

## MEDIA_ACTION
责任模块：MediaActionService / MediaResourceStateStore / UI menu。上下文：`providerID,resourceRef,scopeRef,mutationID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `media.menu.resolved` | `actionIDs,hiddenReasons` | 菜单能力 |
| `media.action.requested` | `action,location` | 操作入口 |
| `media.action.validated` | `capability,ownership` | 校验 |
| `media.action.rejected` | `reasonCode` | 拒绝 |
| `mutation.intent.created` | `field,desired,fieldRevision` | 写意图 |
| `mutation.state.pending` | `field,confirmed,desired,fieldRevision` | pending |
| `mutation.request.started` | `field,requestID` | 真实写 |
| `mutation.receipt.received` | `evidenceFields,statusCode` | 响应 |
| `mutation.patch.merged` | `before,after,preservedFields` | 字段合并 |
| `mutation.state.confirmed` | `field,confirmed,fieldRevision` | 确认 |
| `mutation.superseded` | `supersededBy,reasonCode` | 新意图取代 |
| `mutation.outcome.unknown` | `reasonCode,field` | 结果未知 |
| `mutation.reconcile.begin` | `field,requestID` | 核对 |
| `mutation.reconcile.completed` | `outcome,field,fieldRevision` | 核对终态 |
| `mutation.rollback` | `field,confirmed,reasonCode` | 回滚 |
| `mutation.failed` | `error,field` | 失败 |
| `mutation.observers.notified` | `subscriberCount,fieldRevision` | 订阅 |
| `mutation.read.discarded` | `reasonCode,expectedRevision,actualRevision` | 旧读 |
| `mutation.scope.invalidated` | `previousScopeRef,nextScopeRef,taskCount` | 隔离 |

## PLAYBACK
责任模块：PlaybackIntentService / PlaybackCoordinatorV2 / PlaybackStore。上下文：`intentID,operationID,playbackGeneration,transportRevision,queueID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `playback.intent.created` | `intentKind,location,resourceRef,entryCount` | 点击 |
| `playback.intent.validated` | `expectedScopeRef,expectedQueueID,expectedEpoch` | 校验 |
| `playback.intent.accepted` | `acceptedCount,queueRevision` | 接受非播放确认 |
| `playback.intent.rejected` | `reasonCode` | 拒绝 |
| `playback.intent.superseded` | `newIntentID,reasonCode` | 过期 |
| `playback.target.resolved` | `targetKind,targetRef,providerID` | 实际目标 |
| `playback.prepare.begin` | `targetRef` | 准备 |
| `playback.prepare.completed` | `outcome,durationMs` | 准备终态 |
| `playback.command.dispatched` | `command,engineInstanceID` | 调度 |
| `playback.state.changed` | `desiredTransport,actualBefore,actualAfter,confirmedEntry,pendingEntry` | 真实变化 |
| `playback.current.confirmed` | `entryID,targetRef,evidence` | 引擎确认 |
| `playback.pause.requested` | `positionMs` | 暂停请求 |
| `playback.pause.confirmed` | `positionMs,evidence` | 暂停确认 |
| `playback.resume.requested` | `positionMs` | 继续 |
| `playback.seek.requested` | `targetMs` | seek |
| `playback.seek.completed` | `targetMs,actualMs,outcome` | seek结果 |
| `playback.buffering.begin` | `positionMs,reasonCode` | 缓冲 |
| `playback.buffering.end` | `durationMs,outcome` | 缓冲结果 |
| `playback.track.ended` | `positionMs,durationMs,reasonCode` | 结束 |
| `playback.advance.decided` | `strategy,nextEntryRef,reasonCode` | 推进 |
| `playback.retry.requested` | `targetRef` | 重试 |
| `playback.position.aggregate` | `sampleCount,minMs,maxMs,lastMs` | 聚合 |
| `playback.failed` | `error,stage` | 失败 |
| `playback.intent.completed` | `outcome,confirmationLevel` | 终态 |

## ENGINE
责任模块：AppleMusicWebEngine / generic PlaybackEngineProtocol implementations。上下文：`engineInstanceID,sessionID,operationID,playbackGeneration`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `engine.created` | `engineKind` | 创建 |
| `engine.prepare.begin` | `deadlineMs` | 准备 |
| `engine.ready` | `ready,authorized,evidence` | 就绪 |
| `engine.prepare.completed` | `outcome,durationMs` | 准备终态 |
| `engine.command.sent` | `command,targetRef` | 发送 |
| `engine.command.completed` | `command,outcome,durationMs` | 结束 |
| `engine.command.failed` | `command,error` | 失败 |
| `engine.event.received` | `eventType,itemRef` | 接收 |
| `engine.event.accepted` | `eventType,decision` | 接受 |
| `engine.event.discarded` | `eventType,reasonCode,expectedContext,receivedContext` | 过滤 |
| `engine.crashed` | `reasonCode,recoveryAttempt` | 崩溃 |
| `engine.recovery.begin` | `attempt,limit` | 恢复 |
| `engine.recovery.completed` | `outcome,durationMs` | 恢复终态 |
| `engine.reset` | `reasonCode,outcome` | 重置 |

## BRIDGE
责任模块：WebRuntime / WebBridge / AppleMusicWebEngine。上下文：`engineInstanceID,runtimeRef,operationID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `web.runtime.created` | `storeScopeRef` | 创建 |
| `web.runtime.released` | `outcome` | 释放 |
| `web.navigation.started` | `hostClass,stage` | 导航 |
| `web.navigation.finished` | `durationMs` | 完成 |
| `web.navigation.failed` | `error` | 失败 |
| `bridge.script.injected` | `scriptVersion,outcome` | 注入 |
| `bridge.message.received` | `messageType,fieldPresence` | 桥消息不含原文 |
| `bridge.message.rejected` | `messageType,reasonCode` | 拒绝 |
| `bridge.javascript.exception` | `safeErrorCode,scriptVersion,line` | JS异常 |
| `bridge.waiter.completed` | `outcome,waiterRef` | 等待结束 |

## ENGINE_ROUTER
责任模块：EngineRouter / coordinator boundary。上下文：`switchRef,routingGeneration,engineInstanceID,leaseRef`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `engine.switch.requested` | `fromProvider,toProvider,candidateEngineID` | 交接意图 |
| `engine.switch.preparing` | `candidateEngineID,deadlineMs` | 无声候选 |
| `engine.switch.prepare_failed` | `error,oldEngineState` | 准备失败 |
| `engine.candidate.prepared` | `candidateEngineID,evidence` | 候选就绪 |
| `engine.candidate.discarded` | `candidateEngineID,reasonCode,outcome` | 候选释放 |
| `audio.ownership.release_requested` | `oldEngineID,stopContext` | 停播请求 |
| `audio.ownership.release_confirmed` | `oldEngineID,evidence,confirmationLevel` | 真实停播屏障证据 |
| `audio.ownership.release_failed` | `oldEngineID,error` | 阻断新播放 |
| `audio.ownership.acquired` | `newEngineID,leaseRef` | 转移 |
| `engine.route.command` | `command,requestedEngineID,actualEngineID` | 路由 |
| `engine.route.event_discarded` | `receivedGeneration,expectedGeneration,receivedEngineID,reasonCode` | 旧事件 |
| `engine.switch.completed` | `newEngineID,outcome` | 切换终态 |
| `engine.switch.cancelled` | `reasonCode` | 取消 |
| `engine.switch.rollback` | `outcome,reasonCode` | 实际回滚 |
| `engine.switch.failed` | `stage,error` | 失败 |
| `audio.ownership.violation` | `leaseCount,evidence` | 不变量 |

## QUEUE
责任模块：QueueManager / PlaybackCoordinatorV2。上下文：`queueID,queueRevision,destructiveEpoch,sessionID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `queue.created` | `owner,entryCount` | 新队列 |
| `queue.replaced` | `fromRevision,toRevision,checkpointRef` | 替换 |
| `queue.entries.prepended` | `fromRevision,toRevision,orderedEntryRefs,anchorRef` | 队首 |
| `queue.entries.appended` | `fromRevision,toRevision,orderedEntryRefs,anchorRef` | 队尾 |
| `queue.entries.removed` | `fromRevision,toRevision,removedRefs,positions` | 删除 |
| `queue.entries.moved` | `fromRevision,toRevision,orderedEntryRefs,anchorRef` | 移动 |
| `queue.cleared` | `fromRevision,toRevision,scope,removedCount` | 清空 |
| `queue.undo.applied` | `fromRevision,toRevision,undoRef` | 撤销 |
| `queue.reservation.created` | `entryID,source` | pending |
| `queue.reservation.confirmed` | `entryID,evidence` | 确认 |
| `queue.reservation.failed` | `entryID,error` | 失败 |
| `queue.history.updated` | `fromRevision,toRevision,diff` | 历史 |
| `queue.shuffle.requested` | `requested` | 请求随机 |
| `queue.shuffle.effective` | `effective,orderRef` | 实际顺序 |
| `queue.repeat.changed` | `before,after` | 循环 |
| `queue.loading.changed` | `before,after,loadedCount,totalCount` | 加载 |
| `queue.epoch.changed` | `before,after,reasonCode` | 破坏代数 |
| `queue.operation.rejected` | `reasonCode,expectedContext,receivedContext` | 拒绝 |
| `queue.owner.changed` | `before,after` | 所有权 |
| `queue.checkpoint.captured` | `checkpointRef,revision,partCount` | 检查点 |
| `queue.diff.committed` | `fromRevision,toRevision,commitID,partCount` | 真实提交差量 |
| `queue.invariant.failed` | `invariantID,evidence` | 异常 |

## PAGINATION
责任模块：QueuePaginationLoader / SearchCollectionService。上下文：`batchID,queueID,destructiveEpoch,providerID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `pagination.batch.created` | `initialCount,totalCount` | 批次 |
| `pagination.page.requested` | `pageIndex,cursorRef` | 请求 |
| `pagination.page.received` | `pageIndex,receivedCount,hasNext` | 返回 |
| `pagination.page.committed` | `pageIndex,acceptedCount,loadedCount,revision` | 提交 |
| `pagination.page.discarded` | `reasonCode,pageIndex` | 失效 |
| `pagination.boundary.reached` | `loadedCount,batchID` | 边界 |
| `pagination.cursor.repeated` | `cursorRef,pageIndex` | 循环 |
| `pagination.retry.started` | `cursorRef,pageIndex,attempt` | 重试 |
| `pagination.batch.cancelled` | `reasonCode` | 取消 |
| `pagination.batch.completed` | `totalPages,loadedCount,durationMs` | 完成 |
| `pagination.batch.failed` | `loadedCount,error,partial` | 失败 |

## STATION
责任模块：SearchCollectionService / PlaybackCoordinatorV2 / QueueManager / Engine。上下文：`stationRef,seedRef,currentItemRef,itemSequence,queueID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `station.creation.requested` | `seedKind` | 创建请求 |
| `station.creation.completed` | `stationType,outcome` | 创建结果 |
| `station.session.created` | `owner,stationType` | 会话 |
| `station.connection.started` | `engineInstanceID` | 连接 |
| `station.connection.confirmed` | `evidence` | 连接确认 |
| `station.current_item.changed` | `previousItemRef,currentItemRef,originChanged` | 动态歌曲 |
| `station.metadata.reset` | `clearedFields` | 清除旧关系 |
| `station.capabilities.changed` | `before,after,evidence` | 能力 |
| `station.skip.requested` | `direction` | 切歌 |
| `station.skip.rejected` | `reasonCode` | 拒绝 |
| `station.queue.read_attempted` | `capability` | 远端查询（仅实际支持） |
| `station.queue.unavailable` | `availability,reasonCode` | 未知非零 |
| `station.mode_switch.requested` | `intentKind` | 模式切换 |
| `station.mode_switch.confirmed` | `confirmationRef` | 确认 |
| `station.mode_switch.cancelled` | `reasonCode` | 取消 |
| `station.mode_switch.completed` | `outcome,newOwner,autoPlay` | 完成 |
| `station.restore.completed` | `resumePolicy,stationRef,autoPlay` | 恢复 |
| `station.session.ended` | `reasonCode` | 结束 |

## ORIGIN
责任模块：PlaybackOrigin capture / NavigationService / Dock / LibraryWindowController。上下文：`providerID,entryID,resourceRef,navigationGeneration`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `origin.captured` | `originKind,originRef,routeRef` | 真实上下文 |
| `origin.bound` | `entryID,originRef` | 入队 |
| `origin.confirmed` | `entryID,originRef` | 已确认 |
| `origin.changed` | `previousOriginRef,nextOriginRef` | 来源切换 |
| `origin.metadata.requested` | `itemSequence,requestedKinds` | 补充关系 |
| `origin.metadata.discarded` | `reasonCode,itemSequence` | 旧关系 |
| `origin.menu.resolved` | `actionIDs,dedupCount` | 菜单 |
| `origin.navigation.requested` | `originRef,routeRef` | 跳转 |
| `navigation.route.resolved` | `routeRef,targetProviderID` | 路由 |
| `navigation.page.opened` | `routeRef` | 打开 |
| `navigation.page.reused` | `routeRef` | 复用 |
| `navigation.track.locate.started` | `maxPages,resourceRef` | 定位 |
| `navigation.track.located` | `position,loadedPages` | 位置 |
| `navigation.track.not_found` | `reasonCode,loadedPages` | 未找到 |
| `navigation.failed` | `error` | 失败 |
| `navigation.superseded` | `reasonCode` | 过期 |
| `navigation.completed` | `outcome,causedPlaybackMutation,causedQueueMutation` | 因果副作用 |

## LYRICS
责任模块：LyricsRepositoryV2 / LyricsEngine / PublicSyncedLyricsProvider。上下文：`resourceRef,providerID,requestID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `lyrics.lookup.requested` | `sourcePolicy` | 请求 |
| `lyrics.cache.hit` | `cacheSource` | 命中 |
| `lyrics.candidate.evaluated` | `source,durationDifferenceMs,matchOutcome` | 匹配 |
| `lyrics.lookup.completed` | `source,lineCount,timed,outcome,durationMs` | 结果 |
| `lyrics.parse.failed` | `error` | 解析 |
| `lyrics.result.discarded` | `reasonCode` | 过期 |
| `lyrics.render.updated` | `visibleLineCount` | 低频更新 |

## CACHE
责任模块：LibraryRepositoryV2 / ImageCacheV2 / SQLiteCacheStore / MediaResourceStateStore。上下文：`scopeRef,resourceRef`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `cache.hit` | `cacheKind,tier` | 命中 |
| `cache.miss` | `cacheKind` | 未命中 |
| `cache.stale` | `ageMs,policy` | 陈旧 |
| `cache.swr.started` | `refreshRef` | 后台刷新 |
| `cache.swr.completed` | `outcome,refreshRef` | 刷新终态 |
| `cache.write.completed` | `bytes,outcome` | 写入 |
| `cache.evicted` | `reasonCode,count,bytes` | 淘汰 |
| `cache.scope.invalidated` | `count,reasonCode` | 失效 |
| `cache.stats.aggregate` | `hits,misses,bytes,entryCount` | 聚合 |
| `artwork.download.completed` | `bytes,outcome,durationMs` | 下载 |
| `artwork.decode.completed` | `width,height,durationMs,outcome` | 解码 |
| `artwork.result.discarded` | `reasonCode` | 旧图 |

## PERSISTENCE
责任模块：PlaybackSnapshotStore / SQLiteDatabase / SQLiteCacheStore / credential storage (metadata only)。上下文：`providerID,scopeRef`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `snapshot.save.begin` | `schemaVersion,revision` | 保存 |
| `snapshot.save.completed` | `outcome,bytes,durationMs` | 结果 |
| `snapshot.restore.begin` | `schemaVersion` | 恢复 |
| `snapshot.restore.completed` | `outcome,scopeMatched,owner,resumePolicy` | 恢复结果 |
| `snapshot.migration.completed` | `fromVersion,toVersion,outcome` | 迁移 |
| `snapshot.validation.failed` | `reasonCode` | 校验 |
| `snapshot.scope.rejected` | `reasonCode` | 隔离 |
| `database.open.completed` | `outcome,durationMs` | 数据库打开 |
| `database.migration.completed` | `fromVersion,toVersion,outcome` | 迁移 |
| `database.query.aggregate` | `queryClass,count,p95Ms` | 聚合 |
| `database.transaction.completed` | `outcome,durationMs` | 事务 |
| `database.closed` | `outcome` | 关闭 |
| `storage.io.failed` | `storageClass,error` | I/O异常 |

## UI
责任模块：UnifiedStageController / PlayerView / LibraryWindowController / LiquidFusionQueueDockView / MediaPlayCapsuleMenu / MotionCoordinator。上下文：`windowRef,animationID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `ui.action.triggered` | `action,location,traceID` | 入口 |
| `ui.feedback.presented` | `feedbackCode,outcome,confirmationLevel` | 可见反馈 |
| `ui.state.applied` | `sourceRevision,viewRevision` | 投影 |
| `window.created` | `windowKind,hostRef` | 创建 |
| `window.visibility.changed` | `before,after,reasonCode` | 可见性 |
| `window.mode.changed` | `before,after` | Normal/Mini |
| `window.layout.changed` | `layoutRevision,bounds` | 布局 |
| `window.screen.changed` | `scale,refreshHz` | 屏幕 |
| `window.focus.changed` | `focused` | 焦点 |
| `dock.layout.resolved` | `layoutRevision,bounds` | Dock布局 |
| `dock.bounds.clamped` | `reasonCode` | 边界 |
| `motion.transition.begin` | `transition,from,to,expectedDurationMs` | 动画开始 |
| `motion.transition.reversed` | `reasonCode` | 反向 |
| `motion.transition.interrupted` | `reasonCode` | 抢占 |
| `motion.transition.completed` | `outcome,durationMs` | 终态 |
| `motion.callback.discarded` | `reasonCode,expectedGeneration,actualGeneration` | 过期回调 |
| `glass.material.resolved` | `mode,materialPath,evidence` | 实际材质 |
| `glass.container.layout` | `elementCount,bounds` | 融合布局 |
| `glass.menu.opened` | `menuKind,anchorRef` | 菜单 |
| `glass.menu.closed` | `menuKind,reasonCode` | 关闭 |
| `glass.hit_test.failed` | `reasonCode` | 命中异常 |
| `render.frame.aggregate` | `sampleCount,p50Ms,p95Ms,maxMs,source` | 实际聚合 |
| `render.frame.slow` | `count,budgetMs,source` | 慢帧统计 |
| `accessibility.mode.changed` | `reduceMotion,reduceTransparency` | 辅助功能 |

## DIAGNOSTICS
责任模块：AppLogger / collector / exporter / LogWindowController。上下文：`runID`。

| 事件 | 必需业务字段（适用时） | 触发点 |
|---|---|---|
| `diagnostic.capture.started` | `mode,policyVersion` | 采集 |
| `diagnostic.capture.completed` | `outcome,sequenceRange` | 终态 |
| `diagnostic.events.dropped` | `sequenceRanges,count,levelCounts,reasonCode` | 明确缺口 |
| `diagnostic.sink.failed` | `sink,error,affectedRange` | 落盘失败 |
| `diagnostic.segment.rotated` | `segmentRef,sequenceRange` | 轮转 |
| `diagnostic.segment.evicted` | `segmentRef,sequenceRange,reasonCode` | 覆盖 |
| `diagnostic.snapshot.completed` | `snapshotRef,componentStatuses` | 快照 |
| `diagnostic.export.completed` | `exportRef,outcome,coverage,gapCount` | 导出 |
| `diagnostic.probe.requested` | `probeKind,userConsent` | 主动探测 |
| `diagnostic.probe.completed` | `outcome,durationMs` | 探测终态 |
| `diagnostic.clear.completed` | `scope,outcome` | 清理 |
| `diagnostic.subscriber.changed` | `subscriberCount,visible` | 订阅 |
| `invariant.violation` | `invariantID,evidence,snapshotRef` | 不变量 |

总计 309 个稳定事件。LOG00 为每项建立 emit/owner/test/状态，现有功能外的事件可标 N/A（理由+触发条件），禁止伪造成功。
