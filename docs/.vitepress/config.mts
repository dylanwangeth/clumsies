import { defineConfig } from "vitepress";
import footnote from "markdown-it-footnote";
import container from "markdown-it-container";
import { withMermaid } from "vitepress-plugin-mermaid";

export default withMermaid(
  defineConfig({
    lang: "en-US",
    title: "clumsies",
    description: "Persistent, observable, and collaborative context infrastructure that coexists with agents' self-managed memory.",
    base: "/",
    appearance: true,
    cleanUrls: true,
    lastUpdated: true,
    locales: {
      root: { label: "English", lang: "en-US" },
      zh: {
        label: "中文",
        lang: "zh-CN",
        link: "/zh/",
        themeConfig: {
          outline: {
            level: [2, 3],
            label: "本页目录",
          },
          nav: [
            { text: "概览", link: "/zh/" },
            { text: "工程文档", link: "/zh/engineering-documents" },
            { text: "系统架构", link: "/zh/architecture" },
            { text: "性能与验证", link: "/zh/performance/" },
            { text: "使用指南", link: "/zh/guides/" }
          ],
          sidebar: [
            {
              text: "使用指南",
              items: [
                { text: "指南首页", link: "/zh/guides/" },
                { text: "成员工作流", link: "/zh/guides/how-to-use-clumsies" },
                { text: "Agent 运行时", link: "/zh/guides/agent-runtime" },
                { text: "AgentRun 生命周期", link: "/zh/guides/agent-run-injection" }
              ]
            },
            {
              text: "当前工程文档",
              items: [
                { text: "文档治理", link: "/zh/engineering-documents" },
                { text: "产品概览", link: "/zh/overview" },
                { text: "系统架构", link: "/zh/architecture" },
                { text: "组织记忆", link: "/zh/artifact" },
                { text: "项目", link: "/zh/workspace" },
                { text: "统一 Memory 模型", link: "/zh/unified-memory-model" },
                { text: "macOS Memory 界面", link: "/zh/macos-memory-ui" },
                { text: "本地运行时", link: "/zh/runtime" },
                { text: "服务端", link: "/zh/server" },
                { text: "MCP 接口", link: "/zh/mcp" },
                { text: "宿主适配", link: "/zh/adapter" },
                { text: "Issue 看板需求", link: "/zh/issue-board-requirements" },
                { text: "Issue 看板设计", link: "/zh/issue-board-design" },
                { text: "Memory 检索与评测", link: "/zh/retrieval-evaluation" },
                { text: "活动记录", link: "/zh/recall" },
                { text: "Review 界面", link: "/zh/reviews-ui-design" },
                { text: "代码库地图", link: "/zh/repos" }
              ]
            },
            {
              text: "性能与验证",
              items: [
                { text: "专题索引", link: "/zh/performance/" },
                { text: "服务端热路径", link: "/zh/performance/server-hot-path" },
                { text: "macOS 首次就绪", link: "/zh/performance/macos-first-ready" },
                { text: "延迟模型与诊断", link: "/zh/performance/latency-model" },
                { text: "gzip 因果实验", link: "/zh/performance/gzip-experiment" },
                { text: "签名边界", link: "/zh/performance/signing-boundary" },
                { text: "验证证据台账", link: "/zh/performance/evidence-ledger" }
              ]
            },
            {
              text: "历史记录",
              items: [
                { text: "Project 权威切换", link: "/zh/project-authority-migration" },
                { text: "Memory 存储边界迁移", link: "/zh/guides/rule-store-unification" },
                { text: "Metaprompt 移除", link: "/zh/meta-prompt" },
                { text: "已归档 Zig CLI", link: "/zh/guides/cli-commands" },
                { text: "已归档 Zig TUI", link: "/zh/tui" },
                { text: "已归档 Attestation 客户端", link: "/zh/attestation" }
              ]
            },
            {
              text: "参考资料",
              items: [
                { text: "索引", link: "/zh/reference/" },
                { text: "认证与会话", link: "/zh/reference/auth" },
                { text: "术语表", link: "/zh/glossary" }
              ]
            }
          ],
          docFooter: {
            prev: "上一页",
            next: "下一页"
          },
          lastUpdated: {
            text: "最后更新"
          },
          darkModeSwitchLabel: "外观",
          lightModeSwitchTitle: "切换到浅色模式",
          darkModeSwitchTitle: "切换到深色模式",
          sidebarMenuLabel: "菜单",
          returnToTopLabel: "返回顶部",
          langMenuLabel: "切换语言",
          skipToContentLabel: "跳到正文"
        }
      },
    },
    markdown: {
      config(md) {
        md.use(footnote);

        md.use(container, "expand", {
          render(tokens, idx) {
            const token = tokens[idx];
            const title = token.info.trim().slice("expand".length).trim() || "More";
            if (token.nesting === 1) {
              return `<details class="vp-expand"><summary>${md.utils.escapeHtml(title)}</summary>\n`;
            }
            return "</details>\n";
          },
        });

        md.use(container, "decision", {
          render(tokens, idx) {
            const token = tokens[idx];
            const title = token.info.trim().slice("decision".length).trim() || "Decision";
            if (token.nesting === 1) {
              return `<div class="custom-block decision"><p class="custom-block-title">${md.utils.escapeHtml(title)}</p>\n`;
            }
            return "</div>\n";
          },
        });

        md.renderer.rules.footnote_ref = (tokens, idx) => {
          const id = tokens[idx].meta.id + 1;
          return `<sup class="footnote-ref"><a href="#fn${id}" id="fnref${id}">${id}</a></sup>`;
        };
      },
    },
    themeConfig: {
      search: {
        provider: "local",
        options: {
          locales: {
            zh: {
              translations: {
                button: {
                  buttonText: "搜索",
                  buttonAriaLabel: "搜索文档"
                },
                modal: {
                  displayDetails: "显示详情",
                  resetButtonTitle: "清除搜索",
                  backButtonTitle: "关闭搜索",
                  noResultsText: "没有找到相关结果",
                  footer: {
                    selectText: "选择",
                    selectKeyAriaLabel: "回车键",
                    navigateText: "切换",
                    navigateUpKeyAriaLabel: "向上箭头",
                    navigateDownKeyAriaLabel: "向下箭头",
                    closeText: "关闭",
                    closeKeyAriaLabel: "退出键"
                  }
                }
              }
            }
          }
        }
      },
      outline: {
        level: [2, 3],
        label: "On this page",
      },
      nav: [
        { text: "Overview", link: "/overview" },
        { text: "Engineering docs", link: "/engineering-documents" },
        { text: "Performance", link: "/performance/" },
        { text: "Guides", link: "/guides/" },
        { text: "Reference", link: "/reference/" }
      ],
      sidebar: [
        { text: "Overview", link: "/overview" },
        { text: "Engineering documents", link: "/engineering-documents" },
        {
          text: "Guides",
          items: [
            { text: "Overview", link: "/guides/" },
            { text: "Deployment", link: "/guides/deploy-for-an-org" },
            { text: "Member workflow", link: "/guides/how-to-use-clumsies" },
            { text: "Agent runtime", link: "/guides/agent-runtime" },
            { text: "AgentRun lifecycle", link: "/guides/agent-run-injection" },
            { text: "DSH integration", link: "/guides/dsh-integration" },
            { text: "Development workflow", link: "/guides/development-workflow" }
          ]
        },
        {
          text: "System",
          items: [
            { text: "Architecture", link: "/architecture" },
            { text: "Server", link: "/server" },
            {
              text: "Core model",
              items: [
                { text: "Organization memory", link: "/artifact" },
                { text: "Project", link: "/workspace" },
                { text: "Unified Memory model", link: "/unified-memory-model" }
              ]
            },
            {
              text: "Runtime model",
              items: [
                { text: "Runtime surfaces", link: "/runtime" },
                { text: "macOS Memory UI", link: "/macos-memory-ui" },
                { text: "MCP", link: "/mcp" },
                { text: "Adapter", link: "/adapter" },
                { text: "Issue board requirements", link: "/issue-board-requirements" },
                { text: "Issue board design", link: "/issue-board-design" },
                { text: "Retrieval and evaluation", link: "/retrieval-evaluation" },
                { text: "Activity", link: "/recall" },
                { text: "Reviews UI design", link: "/reviews-ui-design" }
              ]
            },
            { text: "Codebase map", link: "/repos" }
          ]
        },
        {
          text: "Performance and validation",
          items: [
            { text: "Topic index", link: "/performance/" },
            { text: "Server hot path", link: "/performance/server-hot-path" },
            { text: "macOS first-ready", link: "/performance/macos-first-ready" },
            { text: "Latency model and diagnosis", link: "/performance/latency-model" },
            { text: "gzip causal experiment", link: "/performance/gzip-experiment" },
            { text: "Signing boundary", link: "/performance/signing-boundary" },
            { text: "Evidence ledger", link: "/performance/evidence-ledger" }
          ]
        },
        {
          text: "History",
          items: [
            { text: "Project authority cutover", link: "/project-authority-migration" },
            { text: "Memory storage boundary migration", link: "/guides/rule-store-unification" },
            { text: "Metaprompt removal", link: "/meta-prompt" },
            { text: "Archived Zig CLI", link: "/guides/cli-commands" },
            { text: "Archived Zig TUI", link: "/tui" },
            { text: "Archived attestation client", link: "/attestation" }
          ]
        },
        {
          text: "Reference",
          items: [
            { text: "Index", link: "/reference/" },
            { text: "Auth and sessions", link: "/reference/auth" },
            { text: "Glossary", link: "/glossary" }
          ]
        }
      ],
      docFooter: {
        prev: "Previous page",
        next: "Next page"
      },
      lastUpdated: {
        text: "Last updated"
      },
      socialLinks: [
        { icon: "github", link: "https://github.com/lilhammerfun/clumsies" }
      ]
    }
  })
);
