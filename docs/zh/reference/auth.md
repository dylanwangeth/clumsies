# 认证与会话

Server 使用组织 OIDC 建立用户会话。客户端凭据只用于当前 Server 身份；切换 Server、用户或组织时，旧请求、refresh 结果和缓存不得发布到新会话。

本地 daemon 保存运行所需的会话状态，并通过受限的本机边界提供给 Desktop 与 MCP。日志、错误和诊断信息不得包含令牌。

部署时需要分别验证 OIDC 回调、会话过期、401 refresh、登出、身份切换和权限拒绝。认证成功不代表调用者拥有目标 Organization 或 Project 的写权限。
