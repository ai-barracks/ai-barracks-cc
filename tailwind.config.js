/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{js,ts,jsx,tsx}"],
  theme: {
    extend: {
      colors: {
        cc: {
          bg: "var(--cc-bg)",
          sidebar: "var(--cc-sidebar)",
          panel: "var(--cc-panel)",
          border: "var(--cc-border)",
          accent: "var(--cc-accent)",
          "accent-dim": "var(--cc-accent-dim)",
          success: "var(--cc-success)",
          warning: "var(--cc-warning)",
          danger: "var(--cc-danger)",
          text: "var(--cc-text)",
          "text-dim": "var(--cc-text-dim)",
          "text-muted": "var(--cc-text-muted)",
          "card-hover": "var(--cc-card-hover)",
        },
      },
      boxShadow: {
        cc: "var(--cc-shadow)",
      },
    },
  },
  plugins: [require("@tailwindcss/typography")],
};
