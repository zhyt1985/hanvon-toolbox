# 内容导出模块技术方案

版本：0.1\
日期：2026-11-19\
状态：目标技术方案；部分基础组件已实现，接口与配额仍为拟定值，现状见[开发进展](content-export-progress.md)\
对应产品设计：[内容导出模块功能设计](content-export-design.md)

## 1. 技术决策

1. 使用独立内容领域层管理来源、索引、快照、输出和任务；复用现有连接、配对、发现与文件传输基础。
2. USB 和伴侣无线均支持来源读取。原厂 Wi-Fi 只承诺公开文件收集。
3. 无线内容来源采用单独的只读授权，与原有可读写 SharedTree 隔离；按已配对 Mac 授权。
4. 首版先保存可核对的原始资料与设备端导出结果。原始页面转换使用独立、版本化适配器。
5. 所有解析在本机副本上执行，不修改设备数据库；稳定读取与数据库结构完整性分别记录。
6. 使用独立 ExportJob 模型，接入统一任务入口和设备调度器，避免直接扩展持久化 TransferStep.Action 导致旧记录无法解码。
7. 首版不自动跨 USB/Wi-Fi 切换未完成任务，不按型号名合并设备，不假设两种连接的身份标识相同。
8. 不引入云端服务、账号托管、Root、ADB 或 MANAGE_EXTERNAL_STORAGE 作为实现前提。

## 2. 当前实现与复用边界

| 现有位置 | 已有能力 | 本模块处理 |
|---|---|---|
| Sources/ToolboxCore/Device.swift | DeviceConnection、DeviceFolder、DeviceItem | 作为文件传输基础；内容来源使用独立类型，避免改变旧路径语义 |
| USBDevice.swift / MTPWire.swift | MTP 枚举、下载、存储身份 | 按路径重新解析句柄；重连后不复用旧 MTP handle |
| CompanionDevice.swift | 指纹校验、令牌认证、已有 HTTPS 会话 | 提取可复用的认证请求层，新增内容服务客户端 |
| CompanionDiscovery.swift / LANBeacon.swift | Bonjour、UDP 与连接发现 | 原样复用，不增加新配对流程 |
| ResumableTransfers.swift | 1 MiB 分块、缓存、整文件 SHA-256 | 通过新的 ResumeWire 适配器读取内容快照，不直接复用原管理目录路径 |
| TransferBatch.swift | 文件级执行、冲突及中断结果 | 提取公共执行与调度工具；内容复合任务单独持久化 |
| HanvonToolbox/TransferHistory.swift | 现有文件任务 UI | 增加“内容导出”页签和汇总，保留旧模型与记录 |
| SharedTree.java / LanServer.java | 单个可读写目录及 /v1 文件接口 | 保留旧路由；新内容接口只接受已登记的只读来源 |
| ResumeStore.java | 原文件管理目录的续传数据 | 内容快照使用独立存储与所有权；旧续传任务不变 |
| PairedMacs.java | 已配对令牌摘要集合 | 保留令牌；增加按摘要索引的内容授权记录 |
| MainActivity.java / WirelessService.java | 设置、前台服务、网络恢复 | 增加来源管理与授权请求；继续使用同一服务生命周期 |

当前泛用下载可以复制文件，但没有内容级资源闭包、一致性状态和清单，不能直接当作完整笔记备份。普通搜索和同步会跳过部分隐藏文件；内容导出必须自行枚举来源，显式处理 .database、.classify 等必要隐藏资源。

当前 USB 单文件上限略低于 4 GiB；伴侣 0.5.0 普通续传上限为 4 GiB。内容模块仍需施加快照配额，不以传输层上限替代容量检查。

## 3. 模块划分

~~~text
ContentExportWindow / ContentExportModel
                 |
      ContentCatalog / ExportPlanner
                 |
           ExportCoordinator
       /         |             \
SourceProvider  LocalSnapshot  OutputWriter
 USB / Wi-Fi      Validator      Manifest / Bundle / Collector
                 |
        DecoderRegistry（后续转换）

公共基础：DeviceConnection、HTTPS 身份校验、ResumeWire、
          ConnectionSupervisor、DeviceOperationScheduler、ExportJobStore
~~~

建议新增文件如下，均为拟定名称：

| 层 | 文件或组件 | 职责 |
|---|---|---|
| ToolboxCore | ContentModels.swift | 来源、内容、资源及能力模型 |
| ToolboxCore | ContentSourceProvider.swift | 来源发现、索引读取、准备、读取资源、释放 |
| ToolboxCore | USBContentSource.swift | MTP 来源解析与稳定读取 |
| ToolboxCore | CompanionContentSource.swift | 新内容协议及分块下载适配 |
| ToolboxCore | ContentSnapshot.swift | 清单、稳定性检查及来源版本 |
| ToolboxCore | HanvonNoteCatalog.swift | 已验证的 SQLite schema 与笔记索引 |
| ToolboxCore | ContentDecoderRegistry.swift | 格式探测与版本化解码，未知版本失败关闭 |
| ToolboxCore | ExportPlanner.swift / ExportCoordinator.swift | 固化计划、调度、恢复、聚合结果 |
| ToolboxCore | ExportManifest.swift / ExportBundleWriter.swift | 输出目录、来源记录、校验与发布 |
| ToolboxCore | DeviceOperationScheduler.swift | 文件任务与内容任务共享设备互斥 |
| HanvonToolbox | ContentExportWindow.swift / ContentExportModel.swift | 独立窗口及可观察状态 |
| HanvonToolbox | ContentSourceSettingsView.swift / ExportHistoryView.swift | 授权引导、记录与恢复 |
| HanvonToolbox | ExportJobStore.swift / ContentCatalogStore.swift | 原子持久化与迁移 |
| Android | ContentSourceRegistry / ContentAccessPolicy | SAF 来源、授权版本、每台 Mac 的访问策略 |
| Android | ContentSnapshotStore / ContentRoutes | 异步准备、不可变资源、读取与释放 |
| Android | ShareReceiverActivity / ShareInbox | 接收系统分享、显式收集与暂存清理 |

首版不要继续将扫描、解析和导出状态堆入现有 ToolboxModel。由其提供连接上下文和任务入口，独立 ContentExportModel 管理窗口状态。

## 4. 核心数据模型

| 模型 | 必要字段与约束 |
|---|---|
| DeviceBinding | 连接类型、该连接下的设备身份、存储身份；Wi-Fi 使用已核对的完整指纹 |
| ContentSource | sourceID、用途、显示名、grantRevision、provider、只读能力、授权状态 |
| ContentID | sourceID、经过验证的源记录键；不能仅用标题或扫描顺序 |
| ContentItem | 类型或 unclassified、标题、可选时间/时长/页数、附件、识别状态、输出能力 |
| SourceRevision | profileID、schema 指纹、源资源集合及版本摘要；不是单独的修改时间 |
| Artifact | artifactID、来源版本、相对路径、字节数、SHA-256、媒体/格式探测结果 |
| SnapshotDescriptor | snapshotID、owner、sourceID、grantRevision、revision、资源列表、稳定性、租期与缺失项 |
| ExportPlan | jobID、选中 ContentID、冻结的来源版本、输出方式、配置、目标、预期资源 |
| ExportJob | schemaVersion、计划、状态、逐项结果、错误码、续传任务 ID、临时目录、已发布凭据 |
| ExportReceipt | 项目身份、来源版本、输出配置版本、每个正式文件的大小与 SHA-256 |

传输句柄和网络地址仅属于当前会话，不是持久化 ContentID。SQLite 的 _id 是否可作为稳定键，必须经删除、新建、重开和升级样例验证；验证前优先使用已核对的源目录标识，并检测重复或变化。

时间字段在验证毫秒/秒、时区与创建/修改语义后才转换为 Date；保留原始数值与单位解释版本。未知或超出合理范围的值显示为缺失。

USB 序列号与 Wi-Fi 公钥指纹不自动互认。未来若支持跨连接复用历史，必须增加明确的设备绑定与来源内容校验；首版按连接隔离记录。

## 5. 来源与授权

### 5.1 来源注册

无线来源从设备端系统文件选择器产生。ContentSourceRegistry 保存 URI、只读权限、sourceID、grantRevision、用途和允许访问的配对令牌摘要。

- 请求并持久化实际授予的读取权限，不请求整个存储或写权限。
- 即使 provider 同时授予写权限，内容服务也禁止写入源。
- provider 不支持持久化时明确标记“仅本次可用”；首版持久来源验收不得使用这种来源冒充长期授权。
- 根目录、Android/data 等限制按系统实际能力处理，不通过字符串路径或旧版 API 绕过。[Android SAF 授权范围](https://developer.android.com/training/data-storage/shared/documents-files)与[Android 11 限制](https://developer.android.com/about/versions/11/privacy/storage)。
- sourceID 是不透明 ID；Mac 不能提交任意路径或 content URI 让服务代读。
- 来源重新选择、撤销、provider 身份变化均更新 grantRevision；原版本快照不可继续读取。
- 原文件管理的 rootID、URI 和配对令牌保持原样，不通过切换 SharedTree 实现多来源。

### 5.2 按 Mac 授权

已有配对仅认证请求者，不自动授权新增的笔记、录音等来源。新配对和升级前已配对 Mac 的内容授权默认均为空。

Mac 发起请求后，两端显示相同的请求编号和来源范围；用户在电纸书确认。Mac 自报名称只作提示，不能作为身份校验依据。服务端用已认证令牌的摘要关联请求和来源。

每次元数据读取、快照准备、状态查询及分块下载均检查当前配对和来源权限。清除配对、撤销来源或撤销该 Mac 访问后，立即禁止后续读取并清理受影响的设备暂存；不能仅在创建快照时检查一次。

Mac 检测到授权撤销后结束相关任务并清理未发布的正文缓存。此前已完成的正式输出保留，界面说明撤销来源不会撤回这些文件。

### 5.3 来源适配与输出能力

来源用途与识别结果分开。用户选择“笔记来源”不意味着其中所有文件已可转换。能力至少分为：

- 可枚举文件。
- 可读取受支持索引。
- 可识别所选内容与关联资源。
- 可完成指定范围资料包。
- 可转换为指定格式。

不能由“列表出现”推出“完整导出”或“可转 PDF”。能力同时绑定来源、格式档案和转换器版本。

## 6. 索引与原始格式适配

### 6.1 本地 SQLite

Mac 新增薄层 CSQLite 系统库桥接，链接系统 sqlite3，不依赖 Python 或 REA 作为产品运行时。库打开及解析放在后台任务中，设置长度、列数、SQL 长度和执行时限；禁用扩展加载、启用 query_only 与 trusted_schema=OFF，仅执行固定查询并绑定参数。

解析本机私有工作副本。禁止通过来源路径打开或修复设备数据库，禁止执行来源携带的 SQL、触发器或自定义函数。

识别档案至少包含数据库标识、表名、必要列及类型、可选列、时间解释和字段映射。schema 指纹对规范化字段结构求哈希；user_version 和固件名称只作辅助。

已观察的候选结构：

| 数据库 | 主要对象 | 适配要求 |
|---|---|---|
| HvNote.db | NoteList、NoteClass、NoteMark、Label、RecAudio、note_page_info | 验证 name/nameUser、类型、分类、删除状态、资源关系和时间 |
| transPsl.db | transPsl，含路径与重试字段 | 可能是转换任务记录；不得当作权威笔记目录或直接访问其中任意路径 |
| VoiceRecorder/note.db | note、speakers | 验证音频位置、文本 JSON、说话人、时长和笔记关联；当前没有正式记录样例 |

记录给出的路径均视为不可信引用。必须规范化并限制在已授权来源内；跨来源引用只有在另一个来源也已授权并经档案确认时才能解析。

### 6.2 笔记与便签

当前样例只有一种 noteType 值，不能指定其与笔记/便签的映射。M0 用受控新建、修改、删除、移动分类的样例确认；未确认时 ContentItem.kind 为 unclassified。

单项资料包包含选中项的源目录和已确认关联资源，以筛选后的 item.json 保存必要索引。禁止附带包含其他条目标题和内容的整份 HvNote.db。

完整笔记库备份才包含完整索引及隐藏目录；必须枚举未知文件、草稿和资源引用，并将未解析引用报告为缺口。资源闭包尚未验证时，只提供“来源目录原始备份”，不启用“完整笔记库备份”的成功标识。

### 6.3 页面转换

探测器按 magic、版本、结构及长度识别文件，不按扩展名猜测。hvNtDt02、NPSL0001、hvnote09 目前只能作为识别线索，尚无已验证解码器。

转换器必须明确支持页序、尺寸、底纹、笔型、颜色、擦除、旋转、嵌入图像与附件关系，并设置页数、像素和内存上限。只对通过样例验证的版本开放输出能力。

缩略图只能用于列表，不用于静默拼成“完整 PDF”。加密标记和未知格式不绕过；有可保存的原文件时只提供带限制说明的原始资料包。

### 6.4 语音与书信

语音区分独立录音和笔记录音，分别适配来源索引。文件头和媒体探测确认编码；PCM 缺少采样率、声道、位深信息时，不猜测参数转换成 WAV。转写文字仅导出已有且结构已验证的数据，不隐式运行 ASR。

书信适配至少需要正文、发送/接收状态、时间、会话归属及附件完整性证据。hwsys/hvTalk/nim 目前仅确认候选缓存结构，不能视为消息库；没有可读索引时使用设备应用的导出/分享结果收集。

### 6.5 分享收集

伴侣可按实际 MIME 注册 ACTION_SEND / ACTION_SEND_MULTIPLE，处理 EXTRA_STREAM 和授权标志；收到后立即将用户选择的内容复制到私有 ShareInbox，不能假设临时 URI 在重启后仍有效。支持机制见 [Android 接收分享文档](https://developer.android.com/develop/ui/compose/sharing/receive)。

具体汉王应用是否提供系统分享选择器仍需验证。链接型分享只保存为链接及类型说明，不自动抓取网页、云端信件或登录第三方服务。MIME、文件名、大小和真实格式分别校验；接收成功不等于 Mac 导出成功。

## 7. 快照与一致性

### 7.1 三个独立结论

清单分别记录：

| 维度 | 示例状态 | 含义 |
|---|---|---|
| 来源采集 | sourceExportedArtifact / stableReadObserved / sourceChanged / unknown | 文件由原应用导出，或采集期间未观察到变化；后者不保证数据库与附件具有同一时刻状态 |
| 数据结构 | passed / failed / unsupported | SQLite 与文件结构是否通过相应检查 |
| 传输完整性 | sha256Verified / failed | Mac 输出与本次冻结资源的字节是否一致 |

不存在将 quick_check 通过等同于原子快照的状态。UI 使用“文件校验通过”“读取期间未观察到变化”等准确描述；没有原应用协作时不声称事务一致或可恢复。

### 7.2 USB 准备

1. 固化用户选择及范围，提示保存、退出编辑并结束录音。
2. 枚举必要索引、伴随文件、内容文件和关联资源，记录路径、大小及时间。
3. 下载到本机私有工作区，对每个资源计算 SHA-256。
4. 对关键索引和资源集合复查；必要时二次读取并比较哈希。时间和大小不变不能替代哈希。
5. 若发现新增、缺失、变化、非空活跃 journal/WAL 或结构错误，停止该项结构化解析，提示重新准备。
6. 冻结已经采集的资源清单。后续发布只从该副本读取，不再混入新设备版本。

MTP 不能取得原应用的 SQLite 锁。即使多次检查都未观察到变化，仍只能记录 stableReadObserved。若产品要求强一致备份，必须取得原应用生成的导出物或受支持的协作快照。

### 7.3 无线准备

伴侣后台从已授权 SAF 来源生成不可变临时资源。准备期间执行相同的枚举、稳定性及结构检查，结果未就绪前不能下载。

单纯先后复制数据库与 WAL 不构成一致快照；不要先复制主库再忽略 WAL。首版遇到活跃事务文件时停止准备。SAF 可能只提供流，不能假设能用任意文件路径打开数据库或执行 SQLite Backup API。

只有未来通过合法来源取得受支持的数据库连接并经验证，才可采用 [SQLite Backup API](https://sqlite.org/backup.html)；SQLite 的 WAL 与数据库状态关系见[官方 WAL 文档](https://sqlite.org/wal.html)。本机工作副本的结构检查无法证明远端采集是原子的。

快照一旦 ready，不允许追加新版本文件。来源授权撤销时，即使快照已生成也停止对 Mac 提供内容。

## 8. 无线内容协议

### 8.1 能力协商与兼容

沿用现有 /v1/info 的协议字段与旧文件路由，增加可选 contentExport 对象：

~~~json
{
  "contentExport": {
    "protocol": 1,
    "multiSourceReadOnly": true,
    "snapshotDownloads": true,
    "maxChunkBytes": 1048576
  }
}
~~~

该对象只表示服务支持，不表示某来源已授权或某内容已可转换。旧伴侣缺少字段时，新 Mac 禁用直接内容扫描，保留公开文件收集；新伴侣对旧 Mac 的原文件管理行为保持不变。

### 8.2 拟定接口

以下均须已认证；不在 URL 中传递令牌或配对码。ID 为不透明标识，未知或非当前访问者所有的资源不能枚举。

| 方法与路由 | 作用 |
|---|---|
| GET /v1/content/sources | 当前 Mac 可用来源及授权状态；不返回原始 URI |
| POST /v1/content/access-requests | 请求设备端确认指定来源的只读访问 |
| GET /v1/content/access-requests/{id} | 查询授权结果；仅请求者可读 |
| POST /v1/content/snapshots | 异步创建索引或内容快照；返回 202 与 snapshotID |
| GET /v1/content/snapshots/{id} | 准备进度、ready 状态、清单分页、缺失项及租期 |
| POST /v1/content/snapshots/{id}/lease | 用户任务仍活动时延长租期；不突破配额 |
| GET /v1/content/snapshots/{id}/artifacts/{artifactID}/info | 固定大小、SHA-256 和资源版本 |
| GET /v1/content/snapshots/{id}/artifacts/{artifactID}/chunk | 按 offset/count 读取，最大 1 MiB |
| POST /v1/content/snapshots/{id}/transfers/{transferID}/abort | 清理指定下载任务的续传记录，不删除共享快照 |
| POST /v1/content/snapshots/{id}/release | 释放当前任务持有的快照引用 |

创建请求包含 requestID、sourceID、grantRevision、用途、选中源标识或经用户确认的整库范围。服务端重新验证选择，不接受任意路径。requestID 作为幂等键，同键同参数复用创建结果，同键不同参数返回冲突。

索引扫描也通过受控快照获得最少必要文件，Mac 负责解析。元数据快照与内容快照分开，列表加载不预下载所有正文。

分块请求绑定 snapshotID、artifactID、transferID 和已认证所有者；SHA-256 与大小在 ready 后固定。chunk 对单独 GET 请求重复读取是幂等的，不要求服务器维护“已读偏移”。

实现 ContentRoutes 时扩展现有精确路由分发与 HTTP 状态输出，显式支持 202、403、410、422、507 等新状态。JSON 请求体限制为 256 KiB，单次选择最多 500 个内容项；整库模式传范围描述，不提交全部条目 ID。拒绝重复参数、非法 ID、溢出偏移、非预期内容类型和越界分块，不能把异常转换成成功的空资源。

### 8.3 错误协议

新路由采用结构化错误，不改变旧路由的 error 字符串：

~~~json
{
  "error": {
    "code": "SOURCE_CHANGED",
    "message": "来源仍在变化，请保存后重新准备",
    "retryable": false,
    "requestID": "示例请求编号"
  }
}
~~~

| HTTP | code | Mac 处理 |
|---|---|---|
| 401 | PAIRING_REQUIRED | 停止内容请求，沿用现有重新配对入口 |
| 403 | CONTENT_ACCESS_REQUIRED / SOURCE_REVOKED | 等待设备授权，不自动重新配对 |
| 404 | SOURCE_MISSING / ARTIFACT_MISSING | 刷新来源或重新准备，不拼接旧数据 |
| 409 | SOURCE_CHANGED / REVISION_MISMATCH / REQUEST_CONFLICT | 固化失败原因，用户重新生成计划 |
| 410 | SNAPSHOT_EXPIRED | 验证原来源版本后重新准备；旧偏移仅在资源 SHA 相同时可考虑复用 |
| 422 | UNSUPPORTED_FORMAT / UNSTABLE_DATABASE | 保留文件收集入口，禁止结构化成功标记 |
| 429 | BUSY | 使用 Retry-After 与有界退避，不重复创建快照 |
| 507 | SNAPSHOT_QUOTA | 提示分批或清理快照，保留原设备数据 |

### 8.4 拟定资源限制

首版设备端每个内容快照上限 1 GiB、总暂存上限 2 GiB，并保留至少 256 MiB 可用空间；上限由服务端协商返回。超过时提示分批、使用 USB 或收集设备导出物，不静默截断。

每次最多 20,000 个资源、目录深度 64；索引解析最多 50,000 条记录，超出时显示明确范围错误。清单分页每页最多 200 项，元数据响应最多 2 MiB。

同一设备最多一个准备任务和一个活动下载；协调器可采用更严格的串行策略。首版原始转换解码设单页 40 百万像素上限，正式支持前通过样例调整。

快照默认闲置 24 小时过期，活动任务续租。服务重启时检查 journal 并回收过期或未完成资源。暂停超过租期需重新准备；UI 展示服务端租期状态，不能只依赖 Mac 与设备时钟相同。

## 9. 任务执行与恢复

### 9.1 状态机

~~~text
created → preparing → transferring → verifying → publishing → completed
                    ↘ paused / interrupted / waitingAuthorization
                    ↘ failed / cancelled

重试 → 重新验证身份、来源版本、快照及本机目标 → 可恢复阶段
~~~

每个项目有独立状态；任务总体可为 completedWithErrors。只有所有必要资源完成且无缺失时，该项才标为 completed。

准备、传输、校验各自显示进度。未知总量时显示阶段与已处理数量，不生成虚假的百分比。暂停准备任务允许实现为取消当前准备并保留计划，继续时重新准备；只有已 ready 的不可变资源保证字节级续传。

### 9.2 调度与持久化

ExportJobStore 为每个任务写独立版本化 JSON，采用临时文件加原子替换。损坏记录单独隔离，不影响文件传输旧记录。迁移只增可选字段或通过显式版本转换，未知高版本仅展示兼容性提示。

DeviceOperationScheduler 以当前连接身份为互斥键；现有文件管理操作也需接入，防止导出与普通队列同时占用 MTP。用户交互、心跳与后台扫描的优先级须明确，扫描可取消。

内容来源、任务及列表元数据保存在 Application Support/HanvonToolbox/ContentExport。未完成资源使用独立 TransferParts/ContentExport 命名空间，不能仅按标题或路径命名。

### 9.3 续传

无线 ResumeWire 适配器把资源 info/chunk/abort 映射到新内容路由，缓存 scope 至少包含设备指纹、sourceID、grantRevision、snapshotID、artifactID、资源 SHA-256 及 taskID。

当前 ResumableTransfers 会在成功后调用 abort。内容协议中的 abort 只清理传输 journal，不能删除同一任务其他资源还在使用的快照。快照释放由 ExportCoordinator 显式处理。

客户端确认完整分块写入并同步后再更新位置；整文件 SHA-256 匹配后才进入发布。缓存描述、来源或目标变化时停止。设备快照过期后，即使新资源路径相同，也不能直接使用旧偏移；首版重新准备后重新下载，后续可增加同 SHA 的安全复用。

USB 重新连接后按相对路径重新枚举文件，核对版本并下载未完成资源；已校验完成资源保留。不会把当前 USB 字节偏移当作 MTP 原生续传能力。

## 10. 输出清单与发布

### 10.1 清单

manifest.json 使用 schemaVersion、jobID、生成时间、设备/来源绑定、输出模式、适配器版本、稳定性、选中范围、资源清单、大小、SHA-256、缺失项和限制说明。

item.json 保存该项必要的标题、分类、时间解释、原始资源映射及附件关系。result.json 保存逐项完成/跳过/失败/取消结果；错误不包含凭据、正文或联系人。

清单中的设备和来源身份只保存完成追溯所需的值；不保存配对码、令牌和原始 SAF URI。共享导出包前，界面说明其包含用户选择内容及来源元数据。

完整备份与单项资料包使用不同 mode。完整模式才允许包含整份数据库；单项模式的索引是筛选后的规范化元数据，不声称是数据库的逐字节备份。

### 10.2 安全写入

1. 目标目录由 NSOpenPanel 选择并验证；未来启用 App Sandbox 时增加 security-scoped bookmark，不把旧普通 URL 当作已获沙盒授权。
2. 在目标父目录创建唯一导出根目录；每个项目先写入同卷隐藏临时目录。
3. 拒绝符号链接、路径穿越、绝对输出路径、大小写/Unicode 冲突；每个组件都验证，显示名与定位名分开。
4. 校验全部必需资源并写入该项清单，再将项目目录原子更名为正式名称。
5. 更新导出根目录的运行清单与结果。已完成项目可以保留，后续失败不能删掉它们。
6. 崩溃发生在发布后、回执前时，按本任务凭据及全部哈希核对已有输出；不把同名目录直接视为成功。
7. 打包 ZIP 不属于首版，避免在基础导出中引入解压路径、压缩炸弹和新依赖。普通文件夹便于检查原始资料。

本机空间按各卷检查；临时缓存、复制发布及转换可能同时占用空间。初始保守估算为两倍下载字节加转换预算及 256 MiB 余量，未知大小时先完成清单计算。

### 10.3 增量判定

增量键由来源绑定、ContentID、资源集合 SHA-256、输出配置、适配器版本构成。按大小/时间只做候选筛选；最终跳过需核对已存在输出。

删除、改名、移动分类、附加录音、转换器升级及源中新增未知资源都触发重新判断。源删除只显示“来源已不存在”，不执行本机镜像删除。

## 11. 隐私、缓存与日志

- 列表元数据和临时资源目录权限 0700，文件 0600；正式输出采用用户选定位置的访问权限。
- 仅使用已配对 HTTPS 通道；不降低现有指纹校验、不跟随重定向，不向外部站点发送内容。
- 元数据快照只包含该用途必需的索引；正文和音频按选中项准备，缩略图按需加载。
- 诊断日志只记录任务 ID、阶段、错误码、字节计数与耗时。共享诊断包不得附加原数据库和内容。
- 正常完成或取消后清理本机临时正文；暂停缓存默认闲置七天后过期，启动时告知过期任务需重新准备。正式输出不参与缓存清理。
- 本地内容列表默认保留最近一次元数据供离线查看，并标明缓存时间；设置提供“不保留离线列表”和“清理列表与临时缓存”。
- 远端释放失败记录待清理请求；下次原设备可达时执行，设备端租期回收作为兜底。
- 删除来源访问权不会自动删除 Mac 正式输出；清理正式输出须按正常文件管理流程处理。
- 私有权限不等于内容加密；首版不声明独立静态加密或加密笔记解密能力。

## 12. 兼容与迁移

| 组合 | 行为 |
|---|---|
| 新 Mac + 伴侣 0.5.0 或更早 | 原功能正常；直接内容来源提示需升级，公开文件收集可用 |
| 旧 Mac + 新伴侣 | 旧 /v1/info 与原文件接口不变；新增内容来源不自动向旧 Mac 暴露 |
| 新 Mac + 新伴侣 | 原配对自动连接，内容来源仍需单独授权 |
| 来源重新授权 | 更新授权版本；原文件管理 rootID 不变；相关内容任务重新准备 |
| 新固件或新 schema | 优先识别档案；未知版本显示待适配，保持文件级收集 |
| 原有传输记录、同步、回收站 | 格式不变；独立导出记录不改变其恢复和清理规则 |

## 13. 验证计划与开发顺序

### 13.1 受控样例

在 N10 Plus 上新建无隐私样例：两页笔记、单页便签、跨分类/重名笔记、一条带附件书信、十秒独立录音、一条笔记内录音，以及同一笔记的设备端 PDF/图片导出。操作前后记录范围明确的目录及索引差异，验证类型与资源关系。

样例由用户在设备端创建或明确授权的测试操作产生。不复用已删除的私人数据库副本，不把真实笔记正文纳入仓库、日志或自动化夹具。

### 13.2 必要自动化测试

| 类别 | 关键用例 |
|---|---|
| 格式与索引 | 缺列、额外列、新 schema、未知类型、无效时间、损坏 DB、超大字段、重复源键 |
| 资源闭包 | 隐藏索引、跨来源附件、缺失底纹、未知资源、草稿、选中项不泄露未选内容 |
| 权限与协议 | 未授权已配对 Mac、跨 Mac snapshotID、撤销后读块、来源版本替换、路径穿越、幂等请求 |
| 一致性 | 采集时修改、同大小不同内容、非空 WAL/journal、损坏资源、元数据未变但 SHA 改变 |
| 任务恢复 | 分块中断、暂停重开、快照过期、授权等待、取消、发布成功响应丢失、损坏任务记录 |
| 增量与输出 | 输出被移动/篡改、标题重名、Unicode 冲突、新附件、转换器版本变化、无权限与磁盘满 |
| 兼容回归 | 旧传输历史可加载、原 rootID 不变、旧配对可用、原文件续传与 APK 发送不受影响 |

### 13.3 真机放行

先验证 USB 索引及输出，再验证无线同来源同内容；无线仍是首版放行项。必须覆盖后台新建连接、拔 USB 后休眠、唤醒自动重连、服务换端口、主动暂停、退出重开和撤销来源。

已验证的完整资源输出逐文件核对 SHA-256；MTP 前后检查源数据未被修改。原始页面转换还需与设备端导出结果逐页对照，检测页序、裁切、底纹、擦除和附件，不仅比较输出页数。

性能目标先作为测试预算：首屏元数据后台加载、UI 主线程无重任务；在含 1,000 条合成元数据的夹具上筛选交互目标低于 200 ms。真机吞吐量、准备时间和峰值内存测量后记录，不将目标写成实测结果。

### 13.4 可拆分开发任务

| 顺序 | 工作 | 依赖 | 放行条件 |
|---|---|---|---|
| T0 | 固化受控样例、来源档案和字段语义 | 设备配合 | 类型、时间、资源引用有证据；未确定能力保留关闭 |
| T1 | 领域模型、SQLite 桥接、USB 索引与只读来源 | T0 的笔记档案 | 坏数据隔离，列表不触发正文批量下载 |
| T2 | 导出计划、资料包、清单、调度与持久化 | T1 | 单项隐私隔离、稳定读取、哈希与崩溃恢复通过 |
| T3 | 文件收集、导出窗口、任务 UI 与增量 | T2 | 端到端 USB 流程、同名/筛选/部分失败验收 |
| T4 | 伴侣来源授权、按 Mac 权限、内容协议与快照 | T1；可与 T2/T3 按接口并行开发 | 原配对及旧接口回归；撤销与跨 Mac 隔离测试通过 |
| T5 | Mac 无线内容客户端、续传适配与真机回归 | T2、T4 | 不插 USB 完成导出及跨启动续传；首版闭环 |
| T6 | 便签、语音、书信适配 | 各自 T0 结果 | 每类完整性与来源范围单独验收 |
| T7 | 原始页面解码与标准输出 | 受控页面格式样例 | 完整页面质量与未知版本拒绝验证 |

T4 的协议可先用合成资源联调，不需要等待私有页面解码。T0 若不能确认完整笔记库的资源闭包，T2/T3 保留“来源目录原始备份”，不将该能力作为完整可恢复备份交付。

## 14. 设计依据与尚待决策

真机证据来自 2026-11-18 的本地只读目录、格式头和 SQLite schema 检查。三个副本通过 quick_check，17 条笔记记录均只有同一种 noteType，两个录音索引均无记录。原样本已删除；本文保留结构事实，不附个人数据。

本方案不依赖 .build 中的临时调研文件存续。后续用受控夹具固化格式档案，记录设备固件、schema 指纹、magic、适配器版本和不支持范围。

T0 按能力解决笔记/便签类型语义、稳定内容键、页序与资源闭包、系统选择器对各来源的实际可授权性。基础窗口、文件收集及合成资源协议可先开发；未分类列表不等待便签映射，完整资料包和整库备份必须等待各自资源边界验证。语音与书信缺少样例不阻塞笔记和文件收集基础，但阻止对应“完整导出”能力开放。

通用平台依据：

- [Android SAF 目录权限与持久授权](https://developer.android.com/training/data-storage/shared/documents-files)
- [Android 11 跨应用存储限制](https://developer.android.com/about/versions/11/privacy/storage)
- [Android 接收其他应用分享](https://developer.android.com/develop/ui/compose/sharing/receive)
- [SQLite Online Backup API](https://sqlite.org/backup.html)
- [SQLite WAL 行为及只读限制](https://sqlite.org/wal.html)

## 15. 伴侣 0.6.0 实现增量

0.6.0 先交付只读多来源入口；第 8 节的不可变快照协议尚未实现。服务通过 contentExport.protocol=1、sourceReads=true、snapshotDownloads=false 声明能力，不把原始文件分块读取描述为快照。

本阶段实现的静态路由：

| 方法与路径 | 参数 | 行为 |
|---|---|---|
| GET /v1/content/sources | 无 | 来源 ID、授权版本、用途、权限状态；未批准时隐藏实际目录名 |
| POST /v1/content/access-requests | sourceID | 创建或复用当前 Mac 的十分钟待批准请求 |
| GET /v1/content/access-request | id | 仅请求者可查询，返回编号和 pending/approved/denied |
| GET /v1/content/list | sourceID、revision、path | 当前授权下的只读目录列表 |
| GET /v1/content/resume/download/info | sourceID、revision、id、path | 固定任务的当前文件大小与 SHA-256 |
| GET /v1/content/resume/download/chunk | sourceID、revision、id、offset、count | 最多 1 MiB，读取前后重新检查当前权限 |
| POST /v1/content/resume/abort | sourceID、revision、id | 清理该 Mac 的指定续传记录，不删除来源文件 |

这些接口沿用现有 error 字符串响应。Mac 将内容接口的 403 识别为授权失效、409 识别为版本冲突、404 识别为来源或记录缺失；401 保持原配对失效处理。第 8.3 节完整结构化错误码属于后续快照协议工作。

ContentSources 使用独立私有配置，记录 URI、随机 sourceID、随机授权 revision、来源用途和已批准令牌摘要。旧 paired-macs-v2 与文件管理配置不改写。撤销或重新选择来源使旧版本失效；读取每个分块都需要当前配对和该来源权限。

CompanionContentDevice 是虚拟只读连接，所有元数据和下载请求都附加 sourceID/revision。其缓存身份为设备完整指纹加 content/sourceID/revision，与原管理目录的 rootID 无关。已有 ContentSource JSON 增加可选 wirelessSource 描述，缺少字段的旧记录仍可解码。

Mac 检测来源撤销、来源删除、版本变化或配对失效时停止并清理未发布缓存，保留正式输出。来源列表刷新也会处理已暂停的旧授权任务。实际读取仍执行来源稳定性、目录成员与整文件 SHA-256 校验，不能宣称数据库及附件具有同一时刻的一致性。

此增量已在 N10 Plus 验证目录选择、首次批准、64 MiB 资源导出和暂停重开后继续。设备撤销后，旧任务重试被拒绝，30 MiB 未发布缓存及暂存目录被清理，已发布副本哈希不变；原共享目录无线上传、下载及回读核对通过。完整验收范围与未实现能力见[开发进展](content-export-progress.md)。

## 16. 伴侣 0.7.1 固定副本实现增量

本阶段实现第 7 节稳定采集后的不可变资源，能力字段为 contentExport.protocol=1、sourceReads=true、snapshotDownloads=true、maxChunkBytes=1048576。0.6 的独立来源路由与旧文件路由保持兼容；不把稳定采集描述为原应用的原子事务快照。

现有 HTTP 实现使用精确静态路径，参数仍走查询字段，所有 POST 的请求体长度为 0，不接受正文上传。令牌只通过原认证请求头发送。实际路由如下，取代第 8.2 节尚属设计的动态路径形式：

| 方法与路径 | 参数与行为 |
|---|---|
| POST /v1/content/snapshots | requestID/sourceID/revision/path/directory/index/indexSHA256；异步准备一个所选项或经确认的来源目录范围，202 返回状态 |
| GET /v1/content/snapshots/status | snapshotID/offset；状态、准备字节数、已处理文件数、租期秒数和最多 200 条清单；按响应大小进一步缩小页长 |
| POST /v1/content/snapshots/lease | snapshotID/offset；验证授权、续租并返回当前状态 |
| GET /v1/content/snapshots/artifact/info | snapshotID/artifactID；固定路径描述、大小与 SHA-256 |
| GET /v1/content/snapshots/artifact/chunk | snapshotID/artifactID/offset/count；范围内最多 1 MiB 字节，读前后验证权限 |
| POST /v1/content/snapshots/release | snapshotID；释放私有资源，保留用于拒绝误复用的轻量记录 |

每项请求幂等 ID 独立持久化到 Mac 任务行，准备请求的来源版本、范围、目录类型和索引哈希必须相同。不同所有者不能取得状态或资源；过期、已释放的旧 ID 不会自动重建。分块没有设备端偏移记录，客户端的 abort 只清理本机该传输缓存；释放整个副本另走 release。

SnapshotCapture 只通过已批准的 SAF 来源读流，文件复制与二次源哈希均有大小、空间、授权和取消检查。资源物理文件使用随机 UUID 命名，不将设备来源路径直接作为私有存储路径。路径及 Unicode/大小写冲突、目录成员变化、未知大小、非空 WAL/journal 都阻止 ready。单项笔记的索引作为内部校验资源保存，不放进该项 raw 输出。

ContentSnapshots 使用私有 journal 原子写入，后台一次一个准备任务；ready 资源跨服务启动保留，未完成准备在重启后失败并回收。单份 1 GiB、ready 合计 2 GiB、保留空间 256 MiB；准备期间逐块重新检查可用空间。资源数上限 20,000、深度 64、路径元数据预算 4 MiB、序列化清单预算 8 MiB。状态分页不超过 200 项且预留 2 MiB 响应上限。活跃副本数量及轻量记录也有上限。

默认闲置 24 小时回收，状态查询与资源访问续租；租期由设备返回剩余秒数。设备启动和后台定期检查过期、权限失效及配对失效；本地撤销立即取消准备并清理资源。已释放、过期等轻量记录保留一段时间，拒绝旧 ID 意外复用，随后回收。

Mac 新增 ContentSnapshotReference 和 CompanionSnapshotDevice。前者持久化快照 ID、ready 清单 SHA-256 和释放状态；后者只呈现冻结清单并把原续传接口映射到固定 artifactID。缓存 scope 在设备指纹、sourceID/revision 基础上增加 snapshotID，资源 UUID 为任务内传输 ID；缓存描述再绑定固定 SHA-256、路径、目标和大小。旧暂存文件即使已有校验标记，也必须与新副本的资源 SHA-256 相同。

发布前从固定副本清单核对目录成员和索引版本，避免再读取实时来源；文件的最终 SHA-256 必须等于固定资源描述。输出保留 capture=stableReadObserved，并附快照 ID 与清单哈希用于追溯。发布后回执丢失时，先核对本机正式输出，无需重新获取已经释放的副本。发布与取消后尝试释放；网络失败时后续同来源内容操作重试，设备租期回收兜底。

与完整目标方案仍有差异：索引列表扫描暂用原双读稳定性检查；不单独创建持久化的元数据快照。一个导出项对应一份固定副本，批次逐项准备，未实现跨批次共享引用。尚未实现自动恢复任务、同哈希跨快照复用、后台清理面板或原应用协作事务快照。无线原管理目录及 USB 不使用设备固定副本。

自动化覆盖固定副本下载、原来源不再参与下载、跨客户端继续、撤销/过期缓存清理、发布回执恢复、旧版暂存混用拒绝及恶意清单拒绝。Java 测试覆盖范围最小化、ready 字节隔离、同大小源变化、成员变化、空间与大小限制、活动事务、索引变化、冲突名称和撤销。真机结果另记开发进展，不以测试结果替代物理设备验收。


0.7.1 本轮 N10 Plus 验收已完成：64 MiB 固定副本在 Mac 与设备服务重开后沿用同一 ID，暂停后即使设备源被替换为同大小的不同内容，输出仍与旧种子逐字节及 SHA-256 一致；取消释放已确认。来源实际移除后旧快照重试被拒绝，63 MiB 本机未发布缓存及暂存目录清理，已完成输出保持完整；原共享目录移除前后无线读写回归通过，夹具与测试记录已清理。自然过期与低空间真机情形仍待扩充，不由上述结果推定。
