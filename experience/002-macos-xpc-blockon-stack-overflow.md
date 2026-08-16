# 一次 daemon 崩溃循环的完整复盘：从“app 打不开”到 512KB 栈上的 `block_on`

> 关联：Kanban ISSUE-061（系统级诊断与错误透传体系重构）｜日期：2026-08-16｜状态：已修复（XPC 请求异步化）

## 1. 业务场景：用户到底经历了什么

### 1.1 场景还原

2026-08-16 傍晚，用户重启电脑并重新打开 Clumsies app 后：

1. **app 启动失败**：窗口只显示一句泛化的 “The local Clumsies daemon is unavailable.”，
   点“重试”也没有任何改善；
2. **日志“看不到”**：用户（与 agent）在 app 里找不到日志入口，更看不到任何具体错误；
3. **反复无常**：daemon 偶尔能连上几秒，随后又断——GUI 显示 “Connection interrupted”；
4. **次生灾害**：依赖 daemon 的 MCP 工具（memory/kanban）全部断连，agent 无法访问记忆与看板，
   修复会话本身也失去了协作工具；
5. **表象掩盖真相**：看起来像“网络不好”或“daemon 没起来”，实际上是一个每 1-2.5 分钟
   崩溃一次的进程，在被 launchd 静默地反复拉起。

### 1.2 影响面

| 影响 | 说明 |
| --- | --- |
| GUI 不可用 | 看板/设置/同步全部失败 |
| MCP 工具断连 | harness 的 mcp 客户端重连预算耗尽后永久注销工具（需刷新页面） |
| 数据同步停滞 | commit/draft 同步随崩溃反复失败 |
| 排查成本高 | 崩溃无日志、无 panic、无告警，只能靠 macOS .ips 崩溃报告 |

### 1.3 排查旅程（真实过程）

1. **第一层**：日志可见后（ISSUE-061 的日志改造已生效），看到 `clumsiesd.err.log` 刷屏
   `InvalidConfig: schema version 39 is incompatible with version 38`——这是**第一层问题**：
   数据库已被迁移到 v39，而安装的 daemon 还是 v38。修复 schema 后 app 仍不稳定；
2. **第二层**：app 报 `project_agent_adapter_invalid_runtime: ... required release signing identity`——
   这是**第二层问题**：本机无 Developer ID 证书，release 构建无法通过 adapter 签名校验，
   切回 debug 构建后消除；
3. **第三层**：仍反复出现 “Connection interrupted”。这次不再猜，直接读崩溃报告
   `~/Library/Logs/DiagnosticReports/clumsiesd-*.ips`——发现 **daemon 一直在崩溃**，
   崩溃线程队列是 `com.apple.root.default-qos.overcommit`（GCD 全局队列，512KB 栈），
   栈顶在 hyper（HTTP 客户端）的 connect 代码；
4. **定位**：拉出 60+ 帧完整调用栈，真相是 `Handle::block_on` 在 GCD 线程上执行了整个
   `retry_sync → commit_sync → reqwest` 调用链。

**三层问题叠加**：schema 不兼容（部署问题）+ 签名校验（构建问题）+ 栈溢出崩溃（代码问题），
前两层掩盖了第三层——如果没有崩溃捕获机制，第三层永远不会自己“报出来”。

## 2. 代码走读：一次 XPC 请求的完整旅程

### 2.1 入口：GUI 通过 XPC 调用 daemon

GUI（Swift）与 daemon 之间的所有调用走 XPC Mach 服务 `ai.clumsies.daemon`。
服务端监听与消息分发在 `crates/daemon/src/ipc.rs` 的 macOS platform 模块：

```rust
// crates/daemon/src/ipc.rs (修复前)
pub fn start(service_name, service) -> Result<Self, DaemonError> {
    let runtime = Handle::try_current()?;          // 捕获 tokio 运行时句柄
    let listener = xpc_connection_create_mach_service(...);
    let handler = RcBlock::new(move |peer: XpcObject| {
        if object_type(peer) == xpc_connection_type() {
            accept_peer(peer.cast(), service.clone(), runtime.clone());
        }
    });
    xpc_connection_set_event_handler(listener, ...);  // 注册监听回调
    xpc_connection_activate(listener);
}

fn accept_peer(peer, service, runtime) {
    let peer_handler = RcBlock::new(move |message: XpcObject| {
        let response_json = dispatch_message(&service, &runtime, message); // ← 同步！
        // ... 构造回包并发送
    });
    xpc_connection_set_event_handler(peer, ...);
    xpc_connection_activate(peer);
}

fn dispatch_message(service, runtime, message) -> Result<String, DaemonError> {
    let request = serde_json::from_str(&request_json)?;
    let response = runtime.block_on(service.dispatch(request));  // ← 关键问题
    serde_json::to_string(&response)
}
```

**关键事实**：`xpc_connection_set_event_handler` 注册的 block 由 libxpc 派发执行。崩溃报告显示
它实际跑在 GCD default QoS 全局队列（`com.apple.root.default-qos.overcommit`）的线程上——
**栈大小只有 512 KiB**。

### 2.2 桥接：`Handle::block_on` 把 async 请求拉到小栈线程

daemon 的业务层全部是 async（tokio）。XPC 回调是同步的 C block。两者的桥接用了最简单的方式：
在回调线程上 `block_on`——**把整个异步请求“搬”到 512 KiB 栈上同步执行**。
浅请求（health 等）调用链短，没事；深请求（HTTP）直接栈溢出。

### 2.3 深请求：retry_sync 到底做了什么

GUI 在启动/同步失败重试时通过 XPC 调用 `retry_sync`（`crates/daemon/src/state.rs:1117`）：

```rust
// state.rs — DaemonIpcService::retry_sync（XPC 请求入口）
pub async fn retry_sync(&self, request: DaemonSyncRetryRequest) -> Result<...> {
    // 记录重试意图 → 唤醒同步通道
    ...
    self.inner.sync_notify.notify_one();
}

// state.rs:1430 — 同步工作循环
async fn run_sync_channels(&self, sync_drafts, sync_commits, ...) -> Result<(), DaemonError> {
    let _sync_guard = self.inner.sync_lock.lock().await;
    if sync_drafts { draft_sync::run(...).await? }
    if sync_commits { commit_sync::run(...).await? }   // ← 完整 commit 同步
}

// commit_sync.rs:457 — commit 同步的核心
async fn sync_project_ref(state: &DaemonState, project_id: &str) -> Result<(), DaemonError> {
    ...
    let (project_state, project_etag) = fetch_commit_state(state, ...).await?;  // ← HTTP
    ...
}

// server_client.rs:107 — 真正发 HTTP 请求的地方
async fn send_server_request(state, server_url, access_token, method, path, ...) -> Result<reqwest::Response, DaemonError> {
    let mut builder = state.inner.http.get(&url).headers(...);
    let response = builder.send().await?;   // ← reqwest：TCP + TLS + 重试 + 重定向
    ...
}
```

`retry_sync → run_sync_channels → commit_sync::run → sync_project_ref → fetch_commit_state →
send_server_request → reqwest`——**完整调用链在同一线程上展开**。

### 2.4 崩溃点：reqwest 的深嵌套 future

reqwest 一次请求的 future 链（连接池 + DNS + TCP + TLS 握手 + 重试 + 重定向 + 超时）在编译期
展开为 60+ 层嵌套结构（崩溃报告帧 0-43 全部是 hyper/reqwest/futures 的帧）。单次 poll 的栈消耗
可达数百 KB。崩溃报告（`clumsiesd-2026-08-16-193513.ips`）：

```text
exception: EXC_BAD_ACCESS KERN_PROTECTION_FAILURE   ← 踩到栈 guard page
termination: SIGNAL 10 (SIGILL, Bus error)
faultingThread: 21  queue: com.apple.root.default-qos.overcommit   ← GCD 线程，512 KiB 栈
frame 0:   hyper_util::client::legacy::connect::http::connect
frame 44:  daemon::server_client::send_server_request
frame 55:  DaemonIpcService::retry_sync
frame 64:  tokio::runtime::Handle::block_on      ← 同步桥接
frame 67:  block2 __get_invoke_stack_block_invoke ← GCD block 回调
```

## 3. 基础知识：为什么栈大小能杀死进程

### 3.1 线程栈与 guard page

每个线程有独立调用栈，栈尾是只读 guard page。栈耗尽后下一次压栈踩到 guard page，内核发
`SIGSEGV/SIGBUS/SIGILL`（`EXC_BAD_ACCESS`），进程直接死亡，**无异常可捕获**。
Rust async 把“递归”变成编译期展开的嵌套 future：一次 `poll()` 就是一层函数调用链，
大型客户端（reqwest）的链可以展开几十上百层。

### 3.2 macOS 常见线程栈大小（64 位）

| 线程来源 | 默认栈 | 可否调整 |
| --- | --- | --- |
| 主线程 | 8 MiB | 否（系统定） |
| Rust `std::thread` | 2 MiB | 可 `stack_size` 指定 |
| tokio worker | 2 MiB | `thread_stack_size` |
| **GCD 全局队列线程** | **512 KiB** | **不可调整** |
| pthread 默认 | 512 KiB | 创建时可指定 |

### 3.3 XPC / GCD / tokio 三者的关系

- **XPC**：Apple 的 IPC（Mach 消息）。事件处理器（block）由 libxpc 派发到 **GCD 队列**执行；
- **GCD**：全局并发队列（default QoS 为 overcommit），worker 线程栈 512 KiB，不可调大；
- **tokio**：Rust async 运行时，worker 线程 2 MiB。`block_on` = 在**当前线程**同步执行 async 代码；
  `spawn` = 移交到运行时由 worker 执行；
- **桥接问题**：C 回调框架（XPC）+ 异步运行时（tokio）必须共存。同步桥接（block_on）把深栈
  风险引入小栈线程；异步桥接（spawn + 异步回包）才是正解。

## 4. 为什么这个问题“静默”了 5 周

| 层面 | 原因 |
| --- | --- |
| 崩溃本身 | 硬信号不走 Rust panic → daemon.log/err.log 零记录 |
| 进程管理 | launchd KeepAlive 秒级复活 → 看起来“偶发断连” |
| UI | 泛化文案（“daemon is unavailable”）掩盖崩溃循环 |
| 证据 | .ips 报告无人消费（ISSUE-061 验收缺口） |
| 测试 | 单测/CI 不跑真实 XPC + 真实 HTTPS |
| 审查 | `block_on` 桥接在浅请求下完全正常，毫无异常感 |
| 时间线 | 7/8 引入（daemon Rust 化）→ 8/9 首崩 → 8/16 密集爆发（5 周潜伏） |

## 5. 修复方案 A：XPC 请求异步化（代码走读）

### 5.1 设计

```text
修复前（崩溃路径）：
GCD 线程(512K) → block_on(完整 async 请求) → 栈溢出

修复后：
GCD 线程(512K) → 类型检查 → retain → spawn → 立即返回（浅栈）
tokio worker(2M) → 解析 → dispatch.await → 回包 → release
```

### 5.2 实现（crates/daemon/src/ipc.rs）

```rust
fn accept_peer(peer: XpcConnection, service: DaemonIpcService, runtime: Handle) {
    let peer_handler = RcBlock::new(move |message: XpcObject| {
        if object_type(message) != xpc_dictionary_type() { return; }
        // 回调线程只做三件事：retain、clone、spawn，然后立即返回
        let message = unsafe { xpc_retain(message) } as usize;
        let service = service.clone();
        let peer = unsafe { xpc_retain(peer) } as usize;
        runtime.spawn(async move {
            let message = SendXpc(message as *mut c_void);
            let peer = SendXpc(peer as *mut c_void);
            let response_json = dispatch_message(&service, message).await;   // tokio worker 上执行
            if let (Ok(response_json), Ok(reply)) = (response_json, ...) && ... {
                xpc_connection_send_message(peer.0, reply.as_ptr());         // 异步回包
            }
            xpc_release(peer.0); xpc_release(message.0);                     // 归还引用
        });
    });
    ...
}

// 同步 block_on 版本 → 纯 async 版本
async fn dispatch_message(service: &DaemonIpcService, message: SendXpc) -> Result<String, DaemonError> {
    let request_json = xpc_dictionary_string(message.0, REQUEST_JSON_KEY)?;
    let request: DaemonIpcRequest = serde_json::from_str(&request_json)?;
    let response = match validate_agent_runtime_request(&request) {
        Ok(()) => service.dispatch(request).await,   // 在 tokio worker 上 await
        Err(error) => DaemonIpcResponse::from_result(Err(error)),
    };
    serde_json::to_string(&response)
}
```

### 5.3 关键细节

1. **生命周期**：`xpc_retain(message)` 与 `xpc_retain(peer)` 必须成对——对端可能先于任务结束断开，
   不 retain 会悬垂；任务结束统一 release；
2. **Send**：原始指针跨线程进任务，需要一行 `unsafe impl Send`（libxpc 对象线程安全，
   语义正确且最小；社区（xpc-rs、block2）同样做法；代码库 line 746 已有 `as usize` 先例）；
3. **并发**：同一连接上的请求从“串行”变为“可并行”，依赖 state 层既有的锁（sync_lock 等）保证正确性。

### 5.4 观测性补强（ISSUE-061 验收，全部安全 API）

- **panic hook**：`std::panic::set_hook` → 结构化 panic 记录（版本/build_id/线程/backtrace）
  写入 daemon.log 与 `clumsiesd.crash.log`；
- **崩溃循环检测**：启动时对比上次启动时间（`<root_dir>/.daemon-started-at`），<120s 发出结构化告警，
  并提示查看 `.ips` 崩溃报告；
- 明确不写裸信号处理器（sigaltstack + 手写 handler）：unsafe 面大、易错，macOS 本身生成 `.ips`，
  不值得。

## 6. 验证

1. **修复前基线**：GUI 活跃后 1-2.5 分钟内出现新 `.ips`（8/9、8/16 多次命中）；
2. **修复后**：daemon 连续运行 6+ 分钟 pid 恒定、0 新增 .ips、0 重启（观测脚本逐 30s 采样）；
3. **功能**：MCP 冒烟（memory activate + kanban list）EXIT=0；GUI 每 4s XPC 轮询正常回包；
4. **测试**：207 lib + 58 lifecycle 全过；clippy/fmt 干净；
5. **回归建议**：在 512 KiB 栈线程上直接调用 `dispatch_message`，断言不溢出，把本 bug 固化为测试。

## 7. 教训与后续

1. **“连接中断”不等于网络问题**：遇到反复断连先查崩溃报告（.ips），不要猜；
2. **崩溃捕获是观测性的最后一块拼图**：本 bug 暴露了 ISSUE-061 验收项 2 的缺口
   （“崩溃有完整结构化上下文与可追踪记录”），现已补齐 panic hook + 崩溃循环检测；
3. **C 回调框架 × async 运行时**：桥接必须异步化，block_on 只用于“一次性启动”场景；
4. **记忆空间**：本文档将同步存入 memory（`experience/xpc-blockon-stack-overflow`），
   后续 daemon 排查先 activate 相关片段。

## 8. 参考

- 崩溃报告：`~/Library/Logs/DiagnosticReports/clumsiesd-*.ips`
- daemon 日志：`~/Library/Logs/ai.clumsies/{daemon.log,clumsiesd.err.log,clumsiesd.crash.log}`
- [Apple XPC 文档](https://developer.apple.com/documentation/xpc)
- [tokio Handle::block_on](https://docs.rs/tokio/latest/tokio/runtime/struct.Handle.html)
- 同类问题：openai/codex “Run Codex async main on a sized stack”；tokio#6057；pixi#331；
  hickory-dns#1889/#2252（DNS 递归栈溢出）
