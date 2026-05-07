# TUI/CLI 登录设计研究

这份研究梳理 clumsies 在同时拥有 TUI 和 CLI 表面时应该如何设计登录。
重点不是是否保留一个 `login` 命令，而是登录能力应该如何被 TUI、CLI、
MCP/agent 入口共享，并让主交互入口在未认证时自然进入授权流程。

## 当前实现

当前客户端已经有一套可复用的凭据存储：

- `src/client/auth.zig` 保存 `hub_url`、`username`、`access_token`、
  `refresh_token`。macOS 使用 Keychain，其他平台落到
  `~/.clumsies/auth.json`。
- `src/client/commands/login_cmd.zig` 是独立 `clumsies login` 命令。
  它提示 Hub URL、用户名、密码；401 后允许输入 invite token 激活账号。
- `src/client/tui/main.zig` 启动时只尝试 `auth_mod.loadAuth`。失败就继续
  进入 TUI，但 API 状态没有认证信息。
- TUI 空态目前把 `.error_auth` 显示成 `Not authenticated. Run clumsies login.`
- Hub 侧是自有用户名/密码登录，`/api/auth/login` 发 access token 和
  refresh token，`/api/auth/refresh` 轮换两者；还没有 OAuth/device flow。

这说明现状的问题不是缺少登录能力，而是登录能力被绑定到了 CLI 命令入口。
TUI 是主体验时，用户看到的是一个外部指令，而不是一个可完成的登录流程。

## 隐性体验：为什么现在会频繁重新登录

登录入口只是显性体验。更重要的隐性体验是：用户不应该频繁意识到“我又掉线
了，需要重新登录”。Web 产品、GitHub、Google、Stripe 这类工具让用户很少
进入登录流程，依赖的是较长的会话生命周期、后台刷新、设备级授权记录和明确
的安全事件触发，而不是每次客户端启动都重新挑战用户。

当前 clumsies 的频繁重登主要来自四个原因：

1. Hub 默认 `HUB_TOKEN_TTL=3600`，access token 只有 1 小时。
2. refresh token 的 TTL 是 `token_ttl_seconds * 24`，默认也只有 24 小时。
3. 当前 main 上 TUI 启动只加载 `hub_url` 和 `access_token`，没有把
   `username`、`refresh_token` 和刷新回写逻辑接入 bootstrap fetch。
4. refresh 只在请求收到 401 后被动发生，没有启动时的 proactive refresh、
   没有长期 sliding session，也没有“设备已信任”的服务端 session 语义。

即使第 3 点被修复，24 小时 refresh TTL 仍然太短。一个普通用户周五下午用完，
周一早上再打开 TUI，就必然回到登录流程。这个体验会让 CLI/TUI 感觉像临时
脚本，而不是一个长期连接到 Hub 的工作台。

更合理的模型是把 access token 和 refresh/session 分开：

- access token 保持短期，15 分钟到 1 小时都可以。
- refresh token 或 device session 默认 30 到 90 天，按风险可配置。
- 每次 refresh 延长 idle expiry，但保留一个 absolute max lifetime。
- refresh token 轮换可以保留，但不应该把 refresh TTL 绑定到 access TTL。
- 服务端需要支持显式 revoke、token family、reuse detection 和 last_used。
- 客户端启动时如果 access 过期但 refresh 有效，应该静默刷新后进入主界面。

也就是说，目标不是“让 token 永不过期”，而是“正常使用不会频繁打断”。重新
登录应该只在 refresh/session 过期、用户主动 revoke、密码/SSO 安全策略变化、
管理员吊销、设备风险变化这些明确事件发生时出现。

## 隐性体验：Keychain 是否值得保留

当前 `src/client/auth.zig` 在 macOS 上优先使用 Keychain。这个选择安全性强，
但在 clumsies 的开发期和 TUI 高频启动场景里有明显摩擦：macOS 可能在保存或
读取 item 时弹出系统密码确认，尤其是未签名、频繁重编译、路径变化的本地
开发二进制。用户每次登录或 token refresh 都可能被系统密码打断，这比 TUI
内部登录表单更割裂。

这里也需要校正一个事实：Claude Code 官方文档明确说 macOS 上凭据存储在
加密的 macOS Keychain，Linux/Windows 使用 `~/.claude/.credentials.json`
或 `$CLAUDE_CONFIG_DIR` 下的 credentials 文件。Codex 的登录文档强调
ChatGPT 浏览器登录会在本地保存凭据；从 openai/codex 的实现看，它支持
file、keyring、auto、ephemeral 多种 credential store mode。也就是说成熟
工具并不是完全不用 Keychain，而是通常提供可配置的后端和低打扰 fallback。

参考：

- <https://code.claude.com/docs/en/authentication>
- <https://help.openai.com/en/articles/11381614>
- <https://github.com/openai/codex>

对 clumsies 的判断：

- 如果目标是“少打扰”，macOS 默认强依赖 Keychain 不合适。
- 如果目标是“安全默认”，Keychain 有价值，但要避免频繁系统密码挑战。
- 早期开发阶段，未签名二进制和 frequent rebuild 会放大 Keychain 摩擦。
- 自托管/本地 Hub 的威胁模型通常低于公共 SaaS，可接受 0600 文件默认。
- 企业/团队部署以后，可以再提供 managed policy 强制 Keychain 或 secret
  helper。

推荐把凭据存储改成显式可配置：

- `CLUMSIES_AUTH_STORE=file|keychain|auto|memory`
- macOS 开发版默认 `file` 或 `auto` 但不弹窗阻断启动。
- release 版可以默认 `auto`，Keychain 失败就落到 0600 文件。
- 文件路径继续使用 `~/.clumsies/auth.json`，写入 mode `0600`。
- TUI Settings 显示当前 store：`file`、`keychain`、`env`、`memory`。
- `clumsies logout` 必须清掉当前 store，并尽量调用 Hub revoke。
- automation 支持 `CLUMSIES_ACCESS_TOKEN` / `CLUMSIES_REFRESH_TOKEN` 或
  token helper，但不写入磁盘。

如果保留 Keychain，也应该避免把它放在每次 refresh 的热路径上。可以采用
“内存更新立即生效，后台持久化失败只提示一次”的策略；同时避免每小时轮换
refresh token 导致每小时写 Keychain。真正的体验优化来自更长的 refresh
session 和更少的持久化写入。

## 外部方案对比

### GitHub CLI

`gh auth login` 默认使用基于浏览器的登录流程，认证完成后把 token 存入系统
credential store；不可用时 fallback 到明文文件。它也支持 `--with-token`
从 stdin 读 PAT，并支持环境变量 token 作为自动化场景入口。

参考：<https://cli.github.com/manual/gh_auth_login>

判断：GitHub CLI 的模型是“交互式用户走浏览器，自动化走 env/token”。命令
存在，但它是共享认证配置的管理入口，不是唯一用户体验。

### GitHub OAuth Device Flow / RFC 8628

GitHub 文档把 device flow 定位给 CLI/headless 应用：客户端请求 device code
和 user code，提示用户到浏览器输入 code，同时客户端轮询 token endpoint。
RFC 8628 也明确该授权适用于没有浏览器或输入受限的联网设备。

参考：

- <https://docs.github.com/apps/building-oauth-apps/authorizing-oauth-apps>
- <https://www.rfc-editor.org/rfc/rfc8628>

判断：device flow 非常适合 TUI。TUI 可以显示短 code、URL、倒计时、轮询
状态，不需要弹出浏览器，也不需要用户离开 TUI 去执行另一个命令。

### Cloudflare Wrangler

`wrangler login` 使用 OAuth，默认尝试自动打开浏览器。它支持自定义
callback host/port；浏览器打不开时打印 URL；远程机器和容器场景需要用户
手动处理 localhost callback 或映射端口。

参考：<https://developers.cloudflare.com/workers/wrangler/commands/general/>

判断：localhost callback 能提供顺滑体验，但 TUI/SSH/container 场景会明显
变复杂。它适合作为“本机有浏览器”的快速路径，不应该是唯一机制。

### Netlify CLI

`netlify login` 打开浏览器完成 OAuth，授权后将 access token 存到全局
配置文件，后续命令自动使用。

参考：<https://docs.netlify.com/cli/get-started/>

判断：这是典型 SaaS CLI 模式。它比用户名/密码表单更适合 SSO/MFA，但对
纯本地自托管 Hub 需要配套 Web 登录页或 OAuth provider。

### Stripe CLI

`stripe login` 显示 pairing code，并让用户按 Enter 打开浏览器或访问 URL。
如果不想用浏览器，可以用 `--interactive` 输入已有 API key；也支持
`--api-key` 每次请求显式传入。

参考：<https://docs.stripe.com/stripe-cli/install>

判断：pairing code 是 TUI 里最自然的形态：一个可复制 URL、一段 code、
明确的等待状态，以及取消入口。它比在 TUI 内做密码输入更符合现代 CLI
安全习惯。

### gcloud

`gcloud auth login` 使用 Web 授权流，并区分普通 CLI credentials 与 ADC。
它提供 `--no-browser`、`--no-launch-browser`、service account、external
account 等多种 fallback。

参考：

- <https://cloud.google.com/sdk/gcloud/reference/auth/login>
- <https://cloud.google.com/docs/authentication/gcloud>

判断：gcloud 的经验是把“人类交互登录”和“机器/服务账号认证”明确分开。
clumsies 也应该避免把 agent/MCP 场景强行塞进同一个 TUI 登录表单。

### Supabase CLI

`supabase login` 主要使用 personal access token，可存入 native credentials；
CI 场景可跳过 login，直接使用 `SUPABASE_ACCESS_TOKEN`。

参考：<https://supabase.com/docs/reference/cli/supabase-snippets-list>

判断：token 输入适合开发早期和自托管环境，但不应该成为长期主交互，因为它
把用户带到“复制密钥”心智，弱于 OAuth/device flow。

## 设计选项

### 方案 A：继续独立 `clumsies login`

优点是实现最简单，当前已有代码可用，也方便脚本和 CI。缺点是 TUI 启动后
无法自洽，未登录状态只会提示用户离开当前界面；这和 clumsies 想把 TUI 做成
主工作台的方向冲突。

判断：可以保留为低层管理命令，但不应该是唯一入口，也不应该是 TUI 的主要
登录体验。

### 方案 B：TUI 内嵌用户名/密码表单

优点是当前 Hub API 已支持，不需要引入 Web/OAuth。用户在 TUI 内就能完成
登录和 invite activation。缺点是密码表单在 TUI 里要处理输入焦点、隐藏输入、
错误恢复、剪贴板、密码管理器、MFA/SSO 扩展；以后接 Google/GitHub 登录时
仍要重做。

判断：适合作为开发期 fallback，特别是本地 seed/admin 用户、离线 Hub、
invite token 激活。但它不应该成为最终主路径。

### 方案 C：TUI 触发浏览器 OAuth / device flow

TUI 未认证时展示一个登录面板：选择 Hub URL 后调用 hub 的 auth start endpoint。
如果本机适合打开浏览器，可以打开授权 URL；否则显示 URL + code。TUI 轮询
授权状态，成功后保存 token，并直接刷新主界面。

优点是体验完整，不需要用户退出 TUI；适合 Google/GitHub/SSO/MFA；也自然支持
SSH/headless 场景。缺点是需要 Hub 提供 OAuth/device flow 相关 endpoint，
还要处理过期、取消、轮询节流、CSRF/state、防钓鱼提示和 token 绑定。

判断：这是最值得作为目标设计的主路径。

### 方案 D：TUI 启动本地 callback server

客户端本地监听 `127.0.0.1:<port>`，浏览器授权后 redirect 回本地端口，TUI
收到 code 并换 token。

优点是本机浏览器体验很好。缺点是 SSH、容器、远程开发、端口占用、防火墙、
浏览器和 TUI 不在同一台机器时问题多。Wrangler 文档也专门解释了远程和容器
场景的绕法。

判断：可作为优化路径，但不能替代 device flow。

### 方案 E：环境变量 / token file / PAT

允许 `CLUMSIES_TOKEN`、`CLUMSIES_HUB_URL` 或 `--token` 类入口绕过交互登录。

优点是适合 CI、MCP、agent、临时调试和服务账号。缺点是 UX 不适合普通用户，
也更容易泄露长期 token。

判断：必须支持，但定位为 headless/automation fallback。

## 推荐方向

推荐把登录设计拆成“共享 auth flow + 多入口 UI”，而不是“一个 login 命令”。

1. TUI 是主入口：未登录或 token 失效时，TUI 直接切到 Login Panel。
2. Login Panel 的主按钮是 browser/device flow，不是密码表单。
3. 本地开发期保留用户名/密码/invite token 表单作为 fallback。
4. `clumsies login` 可以保留，但改成调用同一套 auth flow，定位为脚本或偏好
   命令行的用户入口。
5. 自动化入口使用环境变量或显式 token，不进入交互式 TUI flow。

产品语义上，用户不是“先运行一个额外命令再打开 TUI”，而是“打开 clumsies 后
完成连接”。CLI 命令只是同一套认证能力的另一个外壳。

## 建议的 clumsies 登录状态机

TUI 中可以把 auth 分成这些状态：

- `no_hub`: 未配置 Hub URL。
- `checking`: 正在加载本地 token 并调用 `/api/auth/me`。
- `anonymous`: 无本地 token，需要登录。
- `authenticating`: 已开始 browser/device flow，等待授权。
- `authenticated`: 已拿到 token，进入主界面。
- `expired`: access/refresh 都不可用，需要重新登录。
- `offline`: Hub 不可达，不能误显示成认证失败。

这会比当前 `.error_auth` / `.error_network` 更清楚。尤其要避免 unauthenticated
health check 把 auth failure 清成 connected。

## 建议的 Hub API 形状

长期目标可以增加：

- `POST /api/auth/device/start`
  返回 `device_code`、`user_code`、`verification_uri`、
  `verification_uri_complete`、`expires_in`、`interval`。
- `POST /api/auth/device/token`
  客户端轮询，返回 `authorization_pending`、`slow_down`、`expired_token`、
  或 access/refresh token。
- `GET /auth/device`
  浏览器页面，用户输入/确认 code。
- `GET /auth/oauth/:provider/start`
  Google/GitHub 等 provider 的 Web OAuth 起点。
- `GET /auth/oauth/:provider/callback`
  Provider callback，完成用户身份绑定，再批准 device/session。

早期如果还没有 Web UI，可以先用 device flow 的“Hub 控制台确认页”或简单
HTML 页面，不必先做完整 SaaS 登录站。

## TUI 交互建议

未登录时第一屏不要显示空 dashboard 加提示文字，而是显示登录面板：

- Hub URL 输入或选择最近使用的 Hub。
- 主操作：`Sign in with browser`。
- 浏览器不可用时显示 URL 和 code，并持续显示轮询状态。
- 次级操作：`Use username/password`、`Use token`、`Quit`。
- 成功后自动进入主界面，不要求重启 TUI。
- token 过期时保留当前 UI 上下文，弹出 re-auth panel；成功后恢复原模块。

这比 `Run clumsies login` 更符合 TUI 应用的完整性。

## 是否“模仿 GitHub”

可以模仿 GitHub CLI 的原则，但不能照搬表面形态：

- 可以学：默认 Web/device flow，系统 credential store，env/token fallback，
  auth status/logout/refresh 作为管理命令。
- 不应照搬：把登录体验完全放到 `auth login` 子命令里。clumsies 的 TUI 是
  默认入口，TUI 必须能自己完成登录。

更准确的目标是：**GitHub CLI 的 auth substrate + Stripe 的 pairing code
体验 + gcloud 的 headless fallback 分层**。

## 近期实现建议

在不等完整 OAuth 的情况下，可以先做一个过渡版：

1. 抽出 `src/client/auth_flow.zig`，让 CLI login 和 TUI Login Panel 共用
   用户名/密码、invite activation、saveAuth、错误分类。
2. TUI 启动无 token 时进入 Login Panel，而不是显示 `Run clumsies login`。
3. Login Panel 先实现 Hub URL、username、password、invite token fallback。
4. 为后续 browser/device flow 预留同一个状态机和 UI 区域。
5. 后续再加 Hub device flow endpoint，把它设为默认按钮。

这样可以先解决“额外 CLI 命令不优雅”的体验问题，又不阻塞长期 OAuth 方向。

## 结论

clumsies 不应该把登录设计成“CLI 命令的前置步骤”。应该把登录作为客户端共享
能力：TUI 在未登录时自己展开 auth flow，CLI 命令只是同一能力的一个外壳。

长期主路径建议是 browser/device flow；用户名/密码表单保留为自托管和开发期
fallback；token/env 入口保留给 CI、MCP 和 agent。这样既能接近 GitHub/Stripe
等成熟 CLI 的安全模型，也符合 clumsies 把 TUI 作为默认工作入口的产品方向。
