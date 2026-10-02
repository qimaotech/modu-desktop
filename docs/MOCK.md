# Debug mock 场景与数据

本文独立定义 `linked-worktree-selected` 场景的临时工作区、示例文件及初始 Git 状态，不依赖原型图片。数据生成位于 [prepare_mock_workspace.py](../script/prepare_mock_workspace.py)，Core 的 [MockWorkspaceFixture.swift](../ModuCore/MockWorkspaceFixture.swift) 负责校验和读取准备好的环境，App 隔离配置位于 [MockWorkspace.swift](../ModuDesktop/MockWorkspace.swift)；开发行为约定见 [PRD 第 12 节](PRD.md#12-开发与验收)，界面样式见 [DESIGN 第 3 节](DESIGN.md#3-详情与外部工具)。修改场景数据时同步本文与实现。

## 1. 启动与隔离

安装 Task 后，从仓库根目录启动（任务入口见 [CI 与本地开发](CI.md#本地任务入口)）：

```bash
task mock
```

检查该实例的构建与启动：

```bash
task verify -- --mock linked-worktree-selected
```

`task debug`、`task logs`、`task telemetry` 也可在 `--` 后传入 `--mock linked-worktree-selected`。仅开发版 App 支持；Release 拒绝该参数，未知或缺少场景名时在启动前报错。

每次运行由脚本创建独立的 `modu-mock-<UUID>/` 临时目录，工作区根为其中的 `example-workspace/`。生成任务与开发版 App 构建并行，不依赖本次构建产物；两项都成功后，脚本通过 `--mock linked-worktree-selected --mock-workspace <root>` 启动 App。App 使用独立的 `ModuMock.<UUID>` 偏好域，Core 支持目录与 CLI home 路径分别指向同一临时目录下的 `support/` 与 `home/`；`home/` 是隔离路径，启动时创建为空目录，只有主动使用 Setup 时才安装临时 CLI。App 不检查或安装用户的真实 CLI，不读取真实工作区，也不终止已运行的普通 App。

脚本创建真实 Git 仓库、提交、linked worktree、示例文件及工作区 JSON 记录，写入已完成的 `mock-session.json`；App 校验临时目录边界、场景、标记与工作区路径，拒绝缺少或无效的准备数据，不自行补建夹具。加载后打开默认成员详情，其他资源详情在后台预加载。夹具生成与 App 的 Git 读取（含 Fork 启动前检查）使用本次临时 `gitconfig`，不读取用户或系统 Git 配置；身份、提交日期、分支、签名、hooks、忽略规则和重命名检测均由夹具配置控制。`https://example.invalid/` 声明通过 `url.insteadOf` 映射到本地 `remotes/`，仅允许 file 协议，禁止网络传输。临时根仓库和主仓库的本地 Git 配置还包含该 `gitconfig`，本次 Git 模板确保后续初始化或克隆的仓库也保留该引用；所有 linked worktree 共享对应配置，外部工具在临时仓库中也能使用本地 remote 映射和示例 Git 配置。

构建或生成失败、取消时，脚本停止本次辅助进程并清理临时文件，不启动 App；App 加载失败显示工作区错误，不进入真实工作区或 Setup。`task verify` 在构建与夹具准备完成后启动 App，只检查本次实例完成 App 启动，输出 PID 后保持运行，启动失败返回非零结果。Agent 按 [开发验证流程](CI.md#agent-开发验证流程) 完成检查后主动退出本次实例并确认清理结果，保留已有实例。正常退出 App 时清理整个临时目录与偏好配置；外部工具打开的目录随之失效，强制终止可能留下残留。需要处理本次未交给 App 或异常终止后保留的数据时，先确认本次实例已退出，再显式运行 `task mock:cleanup DIRECTORY="<本次临时目录>"`，该命令校验场景标记与临时目录边界，不按前缀批量删除。

验证完成、中断或退出 LLDB 时，脚本通过 [进程识别脚本](../script/find_mock_app.py) 按可执行路径和完整的本次 `--mock-workspace` 参数查找存活实例，不依赖窗口标题或进程名。本次实例仍在运行则报告 PID 并保留目录，仍由 Agent 主动退出；没有本次实例才清理本次目录，包括 LLDB 未执行 `run` 就退出或启动失败。进程检查失败时报告并保留数据，避免误删正在使用的目录；不自动退出 App，也不清理其他会话。

临时目录包含以下内容，所有主仓库、seed 仓库、remote 和 worktree 的 Git 对象及登记都位于该目录内：

```text
modu-mock-<UUID>/
├── mock-session.json            # 场景、目录身份、工作区路径及准备完成标记
├── gitconfig
├── templates/config             # 新建 Git 仓库继续引用本次 gitconfig
├── home/                        # Setup 使用的临时 CLI home
├── sources/<仓库名>/             # 7 个生成基线文件的 seed 仓库
├── remotes/<仓库名>.git/         # 7 个本地 bare remote
├── trash/                       # 删除主仓库或失败回收时创建，不使用用户废纸篓
├── support/
│   ├── workspaces/<hash>.json    # Core 保存的工作区记录
│   └── locks/                   # Core 工作区锁
└── example-workspace/
```

## 2. 工作区结构与初始状态

以下路径均相对于本次临时目录中的工作区根：

```text
example-workspace/
├── .git/
├── .gitignore
├── README.md
├── .agents/skills/modu-workflow/SKILL.md
├── repositories/
│   ├── catalog-service/
│   ├── inventory-service/
│   ├── ios-client/
│   ├── macos-client/
│   ├── order-service/
│   ├── payment-service/
│   └── storefront-web/
└── worktrees/
    ├── feature-store-pickup/
    │   ├── inventory-service/
    │   ├── ios-client/
    │   ├── macos-client/
    │   ├── order-service/
    │   └── storefront-web/
    └── fix-overselling/
        ├── inventory-service/
        ├── order-service/
        └── payment-service/
```

7 个仓库均使用仓库名作为展示名，声明 URL 为 `https://example.invalid/<仓库名>.git`，实际连接本次本地 bare remote；不访问网络。两个 Group 的创建时间均固定为 `2026-08-30T00:00:00Z`，成员集合如上。Group 根是真实的工作区 linked worktree，成员是真实的对应主仓库 linked worktree；它们都有 Git 生成的 `.git` 文件和独立的 index。生成脚本将仓库中的 workflow skill 复制到工作区，Group 根随工作区提交检出该文件。

| 项目 | 初始值 |
| --- | --- |
| 工作区名称 | `example-workspace` |
| 语言 | English（`en`） |
| 初始选中资源 | `worktrees/feature-store-pickup/order-service` |
| repositories / worktrees 分区 | 均展开 |
| Group | `feature-store-pickup`、`fix-overselling` 均展开 |
| 资源可用性 | 所有主仓库、Group 根和成员均为可用 |
| dirty 状态 | 仅 `feature-store-pickup/order-service` 和 `feature-store-pickup/storefront-web` 为 dirty，其余均 clean |
| 加载与错误 | 无加载状态，无摘要、Changes 或 Commits 错误 |

## 3. 工具与分支摘要

工具可用性与普通模式一致，按本机安装情况检测。下表列出初始偏好及候选工具，菜单只显示已安装的目标；偏好目标未安装时，按现有工具栏规则选择可用目标。

| 类别 | 初始偏好 | 候选工具 |
| --- | --- | --- |
| Agent | Codex（`codex`） | Codex、Claude Code |
| Git GUI | Fork（`fork`） | Fork |
| Editor | VS Code（`vscode`） | VS Code、Cursor |
| Terminal | Terminal（`terminal`） | Warp、Terminal |

点击主按钮或选择菜单目标，会通过正常外部工具服务真实打开当前临时工作区、Group 或成员目录；成功后仅更新本次 mock 的默认工具。Fork 检查并打开对应真实 Git 工作树，VS Code 等编辑器可直接查看和修改示例文件；打开失败显示正常错误，不假定成功。“Open Workspace in Codex”始终打开本次临时工作区根目录。

| 资源 | Head branch | Base branch | remote 状态 |
| --- | --- | --- | --- |
| `repositories/<仓库名>` | `main` | `origin/main` | 已配置 |
| `worktrees/<Group>` 根 | Group 名称 | 无 | 未配置，隐藏 Base 与 Commits |
| `worktrees/<Group>/<仓库名>` 成员 | Group 名称 | `origin/main` | 已配置 |

所有 Head OID、Base OID 和提交 ID 均从真实 Git 对象读取；不再使用 `7f3a2c1`、`base-main` 等占位值。有 remote 的资源通过实际 `origin/HEAD` 识别 `origin/main`；Group 根未配置 remote，Base OID 为空。

## 4. 初始选中成员的 Changes

目标为 `worktrees/feature-store-pickup/order-service`，Base 为 `origin/main`，Head 为 `feature-store-pickup`。文件路径均相对于该成员目录，`—` 表示该阶段无更改。

| 文件路径 | Staged | Unstaged |
| --- | --- | --- |
| `internal/order/application/create_pickup_order.go` | Added（`A`） | — |
| `internal/order/domain/order.go` | — | Modified（`M`） |
| `internal/order/domain/pickup.go` | Added（`A`） | — |
| `internal/order/infrastructure/persistence/legacy_pickup_repository.go` | — | Deleted（`D`） |
| `internal/order/interfaces/http/pickup_handler.go` | Moved（`R`） | — |

重命名项的原路径为 `internal/order/interfaces/http/order_handler.go`，新路径为表中的 `pickup_handler.go`。Changes 初始展开全部目录，折叠行为沿用当前界面实现。

## 5. 初始选中成员的 Commits

按下表顺序展示，作者均为 Jamie Lee，分页状态 `canLoadMore` 为 false。

| Subject | Author | Date（UTC） |
| --- | --- | --- |
| `test(order): cover pickup fulfillment rules` | Jamie Lee | `2026-08-30T08:18:00Z` |
| `feat(order): validate pickup eligibility` | Jamie Lee | `2026-08-30T06:42:00Z` |
| `feat(order): add pickup fulfillment type` | Jamie Lee | `2026-08-30T03:07:00Z` |

日期固定以 UTC 保存，界面按系统时区格式化。在 Asia/Shanghai 时区、英文界面中，分别显示 `Aug 30, 2026 at 16:18`、`Aug 30, 2026 at 14:42`、`Aug 30, 2026 at 11:07`。

## 6. 其他节点与交互

`worktrees/feature-store-pickup/storefront-web` 仅有以下一项更改，Commits 为空：

| 文件路径 | Staged | Unstaged |
| --- | --- | --- |
| `src/pickup.ts` | — | Modified（`M`） |

其余所有主仓库、Group 根和成员的 Changes、Commits 均为空，分页状态均为 false；空区域沿用 DESIGN 的隐藏规则。各节点的分支摘要按第 3 节提供。

侧栏选择和折叠继续可用，选中节点通过 Core 异步读取对应临时 Git 状态；折叠当前成员所属 Group 时，选择切换到 Group 根。Refresh Changes、Reload Workspace 和 App 激活读取临时仓库实际数据，保留仍有效的当前选择、Group 展开状态及已选择的默认工具，不重新生成或重置文件。外部编辑、暂存、提交或切换分支后的变化可被刷新读取；这些操作只针对临时夹具。清空资源选择时返回工作区开始页，仍使用本次临时工作区与可用工具。

仓库添加、更新、删除，Group 创建、编辑、删除，成员删除及 YAML 导入导出均可用，复用正常模式的校验、删除确认、取消、进度与结果流程。操作会修改本次临时 Git 仓库和工作区记录；刷新不会恢复初始数据。添加与导入可使用 `https://example.invalid/<仓库名>.git` 对应的 7 个本地 remote，例如删除 `catalog-service` 后重新添加；未映射的网络 URL 会失败，不访问网络。新增仓库和自动提交继续使用本次 Git 配置。删除的主仓库回收到本次 `trash/`，worktree 通过 Git 移除，不进入用户废纸篓。

设置中的完整 YAML 导入仍要求当前工作区没有仓库、Group 和资源目录内容，可先删除全部 Group 和仓库再导入；Add Repository 中的 YAML 导入可向现有工作区追加仓库。导入只读取所选文件；导出保存面板初始定位本次临时目录，保存目标必须在该目录内，越界（含符号链接和相似前缀目录）报错且不写入，导出文件随退出清理。

Setup 和工作区切换也可用，可通过目录选择器在本次临时目录内创建、打开和切换其他工作区，所有工作区共用本次隔离的支持目录与 Git 配置。Setup 安装 CLI 到本次 `support/versions/`，链接位于 `home/.local/bin/`，检查使用受控 PATH 和不读取用户启动文件的 shell，不影响真实 CLI。应用业务流程不根据 mock 标志禁用功能；临时依赖与通用路径边界由启动层注入，Core 拒绝对本次临时目录以外的工作区执行打开、配置读写和导出，重新加载与 Setup 同样执行边界检查。加载失败仍显示错误，不回退真实工作区或自动进入 Setup。设置中的语言切换只写入本次独立偏好配置。界面组件、尺寸与图标沿用当前实现，不由本场景另行定义。

## 7. 示例文件内容与提交顺序

所有主仓库的 `main`、本地 remote 和未修改的成员从以下基线文件开始，基线提交标题为 `chore: initialize <仓库名>`，作者与提交者为 Jamie Lee（`jamie@example.invalid`），日期为 `2026-08-29T00:00:00Z`。每个仓库均包含 `README.md`，标明这是临时 Debug 示例。源文件提供最小示例内容，不包含真实业务代码或依赖下载；夹具生成不运行 Go、Swift 或前端构建。

| 仓库 | 基线文件及内容 |
| --- | --- |
| `catalog-service`、`inventory-service`、`payment-service` | `go.mod` 声明 `example.invalid/<仓库名>`、Go 1.22；`internal/service/service.go` 定义 `service.Name` 为仓库名 |
| `ios-client`、`macos-client` | `Sources/Client.swift` 定义含 `id`、`name` 的 `PickupLocation: Identifiable` |
| `storefront-web` | `package.json` 声明私有包 `storefront-web`；`src/pickup.ts` 的 `pickupMessage(location)` 返回 `Pickup location: ${location}` |
| `order-service` | `go.mod` 声明 `example.invalid/order-service`、Go 1.22；`internal/order/domain/order.go` 定义仅含 `ID` 的 `Order`；`internal/order/infrastructure/persistence/legacy_pickup_repository.go` 定义返回 false 的 `LegacyPickupEnabled()`；`internal/order/interfaces/http/order_handler.go` 的 `HandlerName()` 返回 `order` |

仅 `feature-store-pickup/order-service` 在基线上依次创建三条真实提交：

1. `feat(order): add pickup fulfillment type` 添加 `internal/order/domain/fulfillment.go`，定义 `FulfillmentType`、`Delivery` 和 `StorePickup`。
2. `feat(order): validate pickup eligibility` 添加 `internal/order/application/pickup_eligibility.go`，`PickupEligible(locationID)` 判断位置 ID 非空。
3. `test(order): cover pickup fulfillment rules` 添加 `internal/order/domain/fulfillment_test.go`，检查 pickup 与 delivery 类型不同。

提交完成后，再构造第 4 节的未提交状态：新增并暂存 `create_pickup_order.go`（构造含 pickup 位置的订单）和 `pickup.go`（定义含 `LocationID` 的 `Pickup`）；给 `order.go` 增加 `PickupLocationID` 字段但不暂存；删除旧 persistence 文件但不暂存；将 `order_handler.go` 原内容不变地重命名并暂存为 `pickup_handler.go`。因此旧 handler 和已删除的 legacy 文件不在该成员当前目录中，但可从其 Git 历史读取。

最后将 `feature-store-pickup/storefront-web` 的 `pickupMessage(location)` 返回值修改为 `Ready for pickup at ${location}`，不暂存。其余主仓库与成员保持基线状态；Group 根仅检出工作区的 README、忽略规则和 skill，成员目录由已提交的忽略规则排除，根自身保持 clean。
