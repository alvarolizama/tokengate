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
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tokengate"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Drag-and-drop reordering of model_providers within an alias table.
// Native HTML5 DnD on <tr data-id> rows; on drop, pushes the new order so
// the server normalizes priorities 1..N.
const SortableProviders = {
  mounted() {
    this.dragged = null

    this.el.addEventListener("dragstart", e => {
      const row = e.target.closest("tr[data-id]")
      if (!row) return
      this.dragged = row
      e.dataTransfer.effectAllowed = "move"
      try { e.dataTransfer.setData("text/plain", row.dataset.id) } catch (_) {}
      row.classList.add("opacity-40")
    })

    this.el.addEventListener("dragend", () => {
      if (this.dragged) this.dragged.classList.remove("opacity-40")
      this.dragged = null
      this.clearIndicators()
    })

    this.el.addEventListener("dragover", e => {
      if (!this.dragged) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      const row = e.target.closest("tr[data-id]")
      this.clearIndicators()
      if (!row || row === this.dragged) return
      row.classList.add("bg-primary/10")
    })

    this.el.addEventListener("drop", e => {
      if (!this.dragged) return
      e.preventDefault()
      const row = e.target.closest("tr[data-id]")
      this.clearIndicators()
      if (!row || row === this.dragged) return

      const rect = row.getBoundingClientRect()
      const after = (e.clientY - rect.top) > rect.height / 2
      this.el.insertBefore(this.dragged, after ? row.nextSibling : row)

      const ids = Array.from(this.el.querySelectorAll("tr[data-id]")).map(r => r.dataset.id)
      this.pushEvent("reorder_providers", {alias_id: this.el.dataset.aliasId, ids})
    })
  },

  clearIndicators() {
    this.el.querySelectorAll("tr[data-id]").forEach(r => r.classList.remove("bg-primary/10"))
  }
}

// Open/close DaisyUI <dialog> modals via push_event from LiveView.
// Usage: push_event("open_modal", %{id: "my-modal"})
//        push_event("close_modal", %{id: "my-modal"})
const Modal = {
  mounted() {
    this.handleEvent("open_modal", ({id}) => {
      const el = document.getElementById(id)
      if (el && typeof el.showModal === "function") el.showModal()
    })
    this.handleEvent("close_modal", ({id}) => {
      const el = document.getElementById(id)
      if (el && typeof el.close === "function") el.close()
    })
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SortableProviders, Modal},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

