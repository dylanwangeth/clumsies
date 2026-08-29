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
      "/": { label: "English", lang: "en-US" },
      "/zh/": {
        label: "中文",
        lang: "zh-CN",
        themeConfig: {
          outline: {
            level: [2, 3],
            label: "本页目录",
          },
          nav: [
            { text: "概览", link: "/zh/" },
            { text: "工程文档", link: "/engineering-documents" },
            { text: "系统架构", link: "/architecture" },
            { text: "性能与验证", link: "/performance/" },
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
                { text: "文档治理", link: "/engineering-documents" },
                { text: "系统架构", link: "/architecture" },
                { text: "统一 Memory 模型", link: "/unified-memory-model" },
                { text: "macOS Memory 界面", link: "/macos-memory-ui" },
                { text: "本地运行时", link: "/runtime" },
                { text: "Server", link: "/server" },
                { text: "MCP", link: "/mcp" },
                { text: "Issue 看板需求", link: "/issue-board-requirements" },
                { text: "Issue 看板设计", link: "/issue-board-design" },
                { text: "Memory 检索与评测", link: "/retrieval-evaluation" },
                { text: "Activity", link: "/recall" },
                { text: "Reviews UI", link: "/reviews-ui-design" }
              ]
            },
            {
              text: "性能与验证",
              items: [
                { text: "专题索引", link: "/performance/" },
                { text: "Server 热路径", link: "/performance/server-hot-path" },
                { text: "macOS first-ready", link: "/performance/macos-first-ready" },
                { text: "延迟模型与诊断", link: "/performance/latency-model" },
                { text: "gzip 因果实验", link: "/performance/gzip-experiment" },
                { text: "签名边界", link: "/performance/signing-boundary" },
                { text: "验证证据台账", link: "/performance/evidence-ledger" }
              ]
            }
          ],
          docFooter: {
            prev: "上一页",
            next: "下一页"
          },
          lastUpdated: {
            text: "最后更新"
          }
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
      },
      outline: {
        level: [2, 3],
        label: "On this page",
      },
      nav: [
        { text: "Overview", link: "/overview" },
        { text: "Engineering docs", link: "/engineering-documents" },
        { text: "性能与验证", link: "/performance/" },
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
          text: "性能与验证",
          items: [
            { text: "专题索引", link: "/performance/" },
            { text: "Server 热路径", link: "/performance/server-hot-path" },
            { text: "macOS first-ready", link: "/performance/macos-first-ready" },
            { text: "延迟模型与诊断", link: "/performance/latency-model" },
            { text: "gzip 因果实验", link: "/performance/gzip-experiment" },
            { text: "签名边界", link: "/performance/signing-boundary" },
            { text: "验证证据台账", link: "/performance/evidence-ledger" }
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
