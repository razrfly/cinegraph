// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import Alpine from "../vendor/alpine"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import GlobalSearch from "./hooks/global_search"
import ThemeToggle from "./hooks/theme_toggle"
import { initClerkClient, ClerkAuthHandler } from "./auth/clerk-manager"
import ClerkAuthUI from "./hooks/clerk-auth-ui"

window.Alpine = Alpine
Alpine.start()

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// ---------------------------------------------------------------------------
// Clerk token plumbing (#838)
// LiveView auth reads a fresh Clerk JWT via connect_params. Clerk JWTs expire
// quickly (~60s), so we cache + refresh the token for WebSocket reconnections.
// ---------------------------------------------------------------------------
function getCookie(name) {
  const value = `; ${document.cookie}`
  const parts = value.split(`; ${name}=`)
  if (parts.length === 2) return parts.pop().split(";").shift()
  return null
}

let cachedClerkToken = null
let clerkTokenRefreshInterval = null
let clerkVisibilityHandler = null

async function refreshClerkToken() {
  try {
    const session = window.Clerk?.session
    if (session) cachedClerkToken = await session.getToken()
  } catch (e) {
    console.warn("Failed to refresh Clerk token:", e)
    cachedClerkToken = getCookie("__session") || null
  }
}

function startClerkTokenRefresh() {
  refreshClerkToken()
  if (clerkTokenRefreshInterval) clearInterval(clerkTokenRefreshInterval)
  clerkTokenRefreshInterval = setInterval(refreshClerkToken, 30000)

  // Use a named, de-duplicated handler so repeated init (e.g. HMR) doesn't stack
  // listeners that each re-fetch the token on every visibility change.
  if (clerkVisibilityHandler) {
    document.removeEventListener("visibilitychange", clerkVisibilityHandler)
  }
  clerkVisibilityHandler = () => {
    if (document.visibilityState === "visible") refreshClerkToken()
  }
  document.addEventListener("visibilitychange", clerkVisibilityHandler)
}

// Prefer the cached fresh token; fall back to the __session cookie on first load.
function getClerkToken() {
  if (window.currentUser) return null
  return cachedClerkToken || getCookie("__session") || null
}

const Hooks = {
  GlobalSearch,
  ThemeToggle,
  ClerkAuthUI,
  ClerkAuthHandler,
  SectionNav: {
    mounted() {
      const links = this.el.querySelectorAll("[data-section-id]")
      const linkMap = new Map()
      links.forEach(a => linkMap.set(a.dataset.sectionId, a))

      this.observer = new IntersectionObserver(entries => {
        entries.forEach(e => {
          if (e.isIntersecting) {
            links.forEach(l => l.classList.remove("active"))
            linkMap.get(e.target.id)?.classList.add("active")
          }
        })
      }, { rootMargin: "-100px 0px -70% 0px" })

      linkMap.forEach((_, id) => {
        const section = document.getElementById(id)
        if (section) this.observer.observe(section)
      })
    },
    destroyed() { this.observer?.disconnect() }
  }
}

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // Function form: clerk_token is read fresh on every (re)connect (#838).
  params: () => ({
    _csrf_token: csrfToken,
    clerk_token: getClerkToken(),
    current_path: window.location.pathname,
    browser_locale: navigator.language || null,
    browser_locales: navigator.languages || [navigator.language].filter(Boolean),
    browser_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || null
  }),
  hooks: Hooks
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("click", event => {
  const trigger = event.target.closest("[data-scroll-to]")
  if (!trigger) return

  const target = document.getElementById(trigger.dataset.scrollTo)
  if (!target) return

  event.preventDefault()
  history.pushState(null, "", `#${target.id}`)
  target.scrollIntoView({ behavior: "smooth", block: "start" })
})

// Sync top-nav active state — root layout is static and doesn't re-render on live navigation,
// so we update active classes in JS both on initial load and after every live navigation.
function syncNavActive() {
  const path = window.location.pathname
  const active = ["font-semibold", "text-mist-950", "dark:text-white", "bg-mist-950/[0.025]", "dark:bg-white/10"]
  const inactive = ["font-medium", "text-mist-700", "dark:text-mist-400", "bg-transparent"]
  document.querySelectorAll("[data-nav-href]").forEach(el => {
    const href = el.dataset.navHref
    const isActive = path === href || path.startsWith(href + "/")
    isActive ? el.classList.add(...active) : el.classList.remove(...active)
    isActive ? el.classList.remove(...inactive) : el.classList.add(...inactive)
  })
}
// phx:navigate fires on live navigation within the same live_session
window.addEventListener("phx:navigate", syncNavActive)
// phx:page-loading-stop fires when any page finishes loading (including full-reload cross-session navigations)
window.addEventListener("phx:page-loading-stop", syncNavActive)

// connect if there are any LiveViews on the page
liveSocket.connect()

// ---------------------------------------------------------------------------
// Clerk nav hydration (#838)
// The top-nav lives in the root layout (outside the LiveView-managed DOM), so we
// toggle its signed-in / signed-out affordances imperatively rather than via a
// phx-hook. Server-side auth (window.currentUser) wins; otherwise we use Clerk.
// ---------------------------------------------------------------------------
function hydrateClerkNav(user) {
  document.querySelectorAll("[data-clerk-auth-ui]").forEach(el => {
    const loading = el.querySelector("[data-clerk-loading]")
    const signedIn = el.querySelector("[data-clerk-signed-in]")
    const signedOut = el.querySelector("[data-clerk-signed-out]")
    if (loading) loading.classList.add("hidden")
    if (user) {
      signedIn?.classList.remove("hidden")
      signedIn?.classList.add("flex")
      signedOut?.classList.add("hidden")
    } else {
      signedOut?.classList.remove("hidden")
      signedOut?.classList.add("flex")
      signedIn?.classList.add("hidden")
    }
  })
}

// Re-hydrate after live navigation (root layout is static, but a cross-session
// full reload re-renders the skeleton).
window.addEventListener("phx:page-loading-stop", () => {
  if (window.currentUser) hydrateClerkNav(window.currentUser)
})

if (document.querySelector('meta[name="clerk-publishable-key"]')) {
  // Server already knows the user (rendered into window.currentUser): hydrate now.
  if (window.currentUser) {
    hydrateClerkNav(window.currentUser)
  }
  // Initialize Clerk in the background; the __session cookie covers the first
  // LiveView connect, this keeps a fresh token cached for later reconnects.
  initClerkClient()
    .then(() => {
      startClerkTokenRefresh()
      if (!window.currentUser) hydrateClerkNav(window.Clerk?.user || null)
      window.addEventListener("clerk:auth-change", e => hydrateClerkNav(e.detail.user))
    })
    .catch(err => {
      console.warn("Clerk init failed:", err)
      hydrateClerkNav(window.currentUser || null)
    })
} else {
  // Clerk disabled — show the signed-out affordances instead of the skeleton.
  hydrateClerkNav(window.currentUser || null)
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
