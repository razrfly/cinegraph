// ThemeToggle — toggles light/dark mode, persists in localStorage.
// The initial class is set by an inline script in v2_root.html.heex
// (before paint) so we don't FOUC.

const STORAGE_KEY = "cinegraph:theme"

function currentTheme() {
  return document.documentElement.classList.contains("dark") ? "dark" : "light"
}

function applyTheme(theme) {
  const root = document.documentElement
  if (theme === "dark") root.classList.add("dark")
  else root.classList.remove("dark")
  try { localStorage.setItem(STORAGE_KEY, theme) } catch (_) {}
}

const ThemeToggle = {
  mounted() {
    this.handler = () => {
      const next = currentTheme() === "dark" ? "light" : "dark"
      applyTheme(next)
    }
    this.el.addEventListener("click", this.handler)
  },
  destroyed() {
    this.el.removeEventListener("click", this.handler)
  }
}

export default ThemeToggle
