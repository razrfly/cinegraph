// Cinegraph Neutral theme — standalone Tailwind config.
// Extends the main config but adds the `cg.*` color namespace mapping the
// CGT design tokens from `tmp/cinegraph-design/cinegraph/project/cinegraph-components.jsx`.
// Used only by the parallel build that produces `priv/static/assets/cinegraph_neutral.css`.

const mainConfig = require("./tailwind.config.js");

module.exports = {
  ...mainConfig,
  theme: {
    ...mainConfig.theme,
    extend: {
      ...mainConfig.theme.extend,
      colors: {
        ...(mainConfig.theme.extend.colors || {}),
        cg: {
          // Neutrals (warm cool gray)
          bg: "#fafaf9",
          bgAlt: "#f4f3f0",
          surface: "#ffffff",
          surface2: "#f7f6f2",
          border: "#e7e5df",
          border2: "#d8d5cc",
          divider: "#ecebe5",

          // Ink scale
          ink: "#16140f",
          ink2: "#2c2922",
          ink3: "#5d584c",
          mute: "#86806f",
          faint: "#b6b1a3",

          // Brand mark
          mark: "#1a1a17",

          // Restrained accents (status & category)
          blue: "#2a5a8c",
          blueSoft: "#e6edf5",
          green: "#3f6b4a",
          greenSoft: "#e6efe7",
          amber: "#a36a1d",
          amberSoft: "#f5ebd6",
          red: "#9a3f3f",
          redSoft: "#f3e3e1",
        },
      },
    },
  },
};
