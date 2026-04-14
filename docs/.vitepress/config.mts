import { defineConfig } from "vitepress";
import footnote from "markdown-it-footnote";
import container from "markdown-it-container";
import { withMermaid } from "vitepress-plugin-mermaid";

export default withMermaid(
  defineConfig({
    lang: "en-US",
    title: "clumsies",
    description: "Prompt infrastructure for teams: library, workspace, and trace.",
    appearance: "dark",
    cleanUrls: true,
    lastUpdated: true,
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
        { text: "Concepts", link: "/concepts" },
        { text: "Architecture", link: "/architecture" },
        { text: "Repos", link: "/repos" },
        { text: "Guide", link: "/guides/getting-started" }
      ],
      sidebar: [
        {
          text: "Start",
          items: [
            { text: "Home", link: "/" },
            { text: "Overview", link: "/overview" },
            { text: "How to read these docs", link: "/guides/getting-started" }
          ]
        },
        {
          text: "Core",
          items: [
            { text: "Concepts", link: "/concepts" },
            { text: "Architecture", link: "/architecture" },
            { text: "Repo map", link: "/repos" }
          ]
        },
        {
          text: "Reference",
          items: [
            { text: "Index", link: "/reference/" },
            { text: "Screenshot list", link: "/reference/screenshots" }
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
