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
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import GlobalSearch from "./hooks/global_search"
import ThemeToggle from "./hooks/theme_toggle"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const Hooks = {
  GlobalSearch,
  ThemeToggle,
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
  params: {
    _csrf_token: csrfToken,
    browser_locale: navigator.language || null,
    browser_locales: navigator.languages || [navigator.language].filter(Boolean),
    browser_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || null
  },
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

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
