// ThemeToggle — toggles light/dark mode, persists in localStorage.
// The initial class is set by an inline script in v2_root.html.heex
// (before paint) so we don't FOUC.

const STORAGE_KEY = "cinegraph:theme"
const THEME_CHANGE_EVENT = "cinegraph:theme-change"

function currentTheme() {
  return document.documentElement.classList.contains("dark") ? "dark" : "light"
}

function preferredTheme() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

function syncA11y(el) {
  el.setAttribute("aria-pressed", currentTheme() === "dark" ? "true" : "false")
}

function applyTheme(theme) {
  const root = document.documentElement
  if (theme === "dark") root.classList.add("dark")
  else root.classList.remove("dark")
  try { localStorage.setItem(STORAGE_KEY, theme) } catch (_) {}
  window.dispatchEvent(new CustomEvent(THEME_CHANGE_EVENT, { detail: { theme } }))
}

const ThemeToggle = {
  mounted() {
    this.handler = () => {
      const next = currentTheme() === "dark" ? "light" : "dark"
      applyTheme(next)
      syncA11y(this.el)
    }
    this.syncHandler = () => syncA11y(this.el)
    this.storageHandler = (event) => {
      if (event.key !== STORAGE_KEY) return
      const root = document.documentElement
      const theme =
        event.newValue === "dark" || event.newValue === "light"
          ? event.newValue
          : preferredTheme()
      if (theme === "dark") root.classList.add("dark")
      else root.classList.remove("dark")
      syncA11y(this.el)
    }
    syncA11y(this.el)
    this.el.addEventListener("click", this.handler)
    window.addEventListener(THEME_CHANGE_EVENT, this.syncHandler)
    window.addEventListener("storage", this.storageHandler)
  },
  destroyed() {
    this.el.removeEventListener("click", this.handler)
    window.removeEventListener(THEME_CHANGE_EVENT, this.syncHandler)
    window.removeEventListener("storage", this.storageHandler)
  }
}

export default ThemeToggle
