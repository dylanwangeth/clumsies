import { defineConfig } from "vitepress";
import footnote from "markdown-it-footnote";
import container from "markdown-it-container";
import { withMermaid } from "vitepress-plugin-mermaid";

export default withMermaid(
  defineConfig({
    lang: "en-US",
    title: "clumsies",
    description: "Persistent, observable, and collaborative context infrastructure that coexists with agents' self-managed memory.",
    base: process.env.GITHUB_ACTIONS ? "/clumsies/" : "/",
    appearance: true,
    cleanUrls: true,
    lastUpdated: true,
    locales: {
      "/": { label: "English", lang: "en-US" },
      "/zh/": { label: "中文", lang: "zh-CN" },
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
        { text: "Guides", link: "/guides/" },
        { text: "Reference", link: "/reference/" }
      ],
      sidebar: [
        { text: "Overview", link: "/overview" },
        {
          text: "Guides",
          items: [
            { text: "Overview", link: "/guides/" },
            { text: "Deployment", link: "/guides/deploy-for-an-org" },
            { text: "Member workflow", link: "/guides/how-to-use-clumsies" },
            { text: "Agent runtime", link: "/guides/agent-runtime" },
            { text: "AgentRun lifecycle", link: "/guides/agent-run-injection" }
          ]
        },
        {
          text: "System",
          items: [
            { text: "Architecture", link: "/architecture" },
            {
              text: "Core model",
              items: [
                { text: "Hub", link: "/artifact" },
                { text: "Project", link: "/workspace" }
              ]
            },
            {
              text: "Runtime model",
              items: [
                { text: "Runtime surfaces", link: "/runtime" },
                { text: "MCP", link: "/mcp" },
                { text: "Adapter", link: "/adapter" },
                { text: "Issue board requirements", link: "/issue-board-requirements" },
                { text: "Issue board design", link: "/issue-board-design" },
                { text: "META_PROMPT", link: "/meta-prompt" }
              ]
            },
            { text: "Codebase map", link: "/repos" }
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
