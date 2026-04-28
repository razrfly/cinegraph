// Oatmeal (mist_instrument) theme — standalone Tailwind config.
// Mirrors the upstream Oatmeal kit's `@theme` block from
// `tmp/oatmeal-mist-instrument/README.md`, translated to Tailwind v3 JS config.
// Used only by the parallel build that produces `priv/static/assets/oatmeal.css`.

const mainConfig = require("./tailwind.config.js");

module.exports = {
  ...mainConfig,
  theme: {
    ...mainConfig.theme,
    extend: {
      ...mainConfig.theme.extend,
      colors: {
        ...(mainConfig.theme.extend.colors || {}),
        mist: {
          50: "oklch(98.7% 0.002 197.1)",
          100: "oklch(96.3% 0.002 197.1)",
          200: "oklch(92.5% 0.005 214.3)",
          300: "oklch(87.2% 0.007 219.6)",
          400: "oklch(72.3% 0.014 214.4)",
          500: "oklch(56% 0.021 213.5)",
          600: "oklch(45% 0.017 213.2)",
          700: "oklch(37.8% 0.015 216)",
          800: "oklch(27.5% 0.011 216.9)",
          900: "oklch(21.8% 0.008 223.9)",
          950: "oklch(14.8% 0.004 228.8)",
        },
      },
      fontFamily: {
        ...(mainConfig.theme.extend.fontFamily || {}),
        display: ['"Instrument Serif"', "serif"],
        sans: ["Inter", "system-ui", "sans-serif"],
      },
    },
  },
};
