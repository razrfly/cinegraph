// GlobalSearch hook — keyboard polish and localStorage recents for the
// CinegraphWeb.GlobalSearchLive typeahead.
//
// Responsibilities:
//   * ⌘K / Ctrl+K anywhere on the page focuses the search input.
//   * Esc closes the dropdown and blurs the input.
//   * ↑ / ↓ moves a CSS-only highlight across visible result rows;
//     Enter clicks the highlighted row. (No server roundtrip — too slow.)
//   * Persist recent selections to localStorage and push them to the
//     LiveView on mount so the focused-empty panel renders correctly.

const STORAGE_KEY = "cinegraph:search:recents"
const MAX_RECENTS = 5

function readRecents() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.slice(0, MAX_RECENTS) : []
  } catch (_) {
    return []
  }
}

function writeRecents(items) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(items.slice(0, MAX_RECENTS)))
  } catch (_) { /* quota or private mode — fail silently */ }
}

function pushRecent(item) {
  const existing = readRecents()
  // Dedup by href so re-clicking the same row doesn't pile up duplicates.
  const filtered = existing.filter(r => r.href !== item.href)
  writeRecents([item, ...filtered])
}

const HIGHLIGHT_CLASS = "global-search-highlight"

const GlobalSearch = {
  mounted() {
    this.input = this.el.querySelector("#global-search-input")
    this.listboxId = "global-search-listbox"

    // Push current recents to the LiveView so the empty-state panel renders.
    const recents = readRecents()
    if (recents.length > 0) {
      this.pushEventTo(this.el, "update_recents", { recents })
    }

    this.handleWindowKeydown = (e) => {
      const isCmdK = (e.metaKey || e.ctrlKey) && e.key === "k"
      if (isCmdK) {
        e.preventDefault()
        this.input?.focus()
        this.input?.select()
        this.pushEventTo(this.el, "focus", {})
      }
    }

    this.handleInputKeydown = (e) => {
      switch (e.key) {
        case "Escape":
          e.preventDefault()
          this.input.value = ""
          this.input.dispatchEvent(new Event("input", { bubbles: true }))
          this.input.blur()
          this.clearHighlight()
          break
        case "ArrowDown":
          e.preventDefault()
          this.moveHighlight(1)
          break
        case "ArrowUp":
          e.preventDefault()
          this.moveHighlight(-1)
          break
        case "Enter":
          if (this.highlightedRow()) {
            e.preventDefault()
            this.highlightedRow().click()
          }
          break
      }
    }

    this.handleClick = (e) => {
      const row = e.target.closest("a[role='option']")
      if (!row) return

      // Pull a label from the row's leading text node for the recent entry.
      const titleEl = row.querySelector(".text-mist-950") ?? row
      pushRecent({
        href: row.getAttribute("href"),
        label: titleEl.textContent.trim().slice(0, 80)
      })
    }

    window.addEventListener("keydown", this.handleWindowKeydown)
    this.input?.addEventListener("keydown", this.handleInputKeydown)
    this.el.addEventListener("click", this.handleClick)
  },

  updated() {
    // After every server render the rows may have changed — clear stale
    // highlight state so ↑/↓ starts fresh.
    this.clearHighlight()
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleWindowKeydown)
    this.input?.removeEventListener("keydown", this.handleInputKeydown)
    this.el.removeEventListener("click", this.handleClick)
  },

  // ---- highlight helpers -------------------------------------------------

  rows() {
    const listbox = document.getElementById(this.listboxId)
    if (!listbox) return []
    return Array.from(listbox.querySelectorAll("a[role='option']"))
  },

  highlightedRow() {
    return this.el.querySelector(`.${HIGHLIGHT_CLASS}`)
  },

  clearHighlight() {
    this.highlightedRow()?.classList.remove(HIGHLIGHT_CLASS)
  },

  moveHighlight(delta) {
    const all = this.rows()
    if (all.length === 0) return

    const current = this.highlightedRow()
    let nextIdx
    if (!current) {
      nextIdx = delta > 0 ? 0 : all.length - 1
    } else {
      const idx = all.indexOf(current)
      nextIdx = (idx + delta + all.length) % all.length
      current.classList.remove(HIGHLIGHT_CLASS)
    }

    const next = all[nextIdx]
    next.classList.add(HIGHLIGHT_CLASS)
    next.scrollIntoView({ block: "nearest" })
  }
}

export default GlobalSearch
