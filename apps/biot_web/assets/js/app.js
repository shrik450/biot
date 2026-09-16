import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/biot_web"

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
let ghosttyWebPromise

const loadGhosttyWeb = () => {
  if (!ghosttyWebPromise) {
    ghosttyWebPromise = import("/assets/vendor/ghostty-web-0.4.0.js").then(async ({Ghostty, Terminal, FitAddon}) => ({
      ghostty: await Ghostty.load("/assets/vendor/ghostty-vt-0.4.0.wasm"),
      Terminal,
      FitAddon,
    }))
  }

  return ghosttyWebPromise
}

const hooks = {
  ...colocatedHooks,
  CredentialNotice: {
    disconnected() {
      this.el.textContent = ""
    },
    destroyed() {
      this.el.textContent = ""
    },
  },
  CopyCredential: {
    mounted() {
      this.el.addEventListener("click", async () => {
        const target = document.querySelector(this.el.dataset.copyTarget)
        const value = target?.textContent?.trim()

        if (!value) return

        try {
          await navigator.clipboard.writeText(value)
          this.el.textContent = "copied"
        } catch (_error) {
          this.el.textContent = "copy unavailable"
        }
      })
    },
  },
  FormBehavior: {
    mounted() {
      this.submitted = false
      this.submit = () => { this.submitted = true }
      this.el.addEventListener("submit", this.submit)

      if (this.el.dataset.unsavedChanges === "true") {
        this.dirty = false
        this.markDirty = () => { this.dirty = true }
        this.beforeUnload = event => {
          if (!this.dirty || this.submitted) return
          event.preventDefault()
          event.returnValue = ""
        }
        this.beforeNavigate = event => {
          if (!this.dirty) return

          if (this.submitted) {
            this.dirty = false
            return
          }

          if (window.confirm("Leave this page? unsaved changes will be lost.")) {
            this.dirty = false
          } else {
            event.preventDefault()
          }
        }
        this.el.addEventListener("input", this.markDirty)
        this.el.addEventListener("change", this.markDirty)
        window.addEventListener("beforeunload", this.beforeUnload)
        window.addEventListener("phx:before-navigate", this.beforeNavigate)
      }
    },
    updated() {
      const submitted = this.submitted
      this.submitted = false
      if (this.el.dataset.clearSensitive === "true" && submitted) {
        this.clearSensitiveInputs()
      }
      if (!submitted) return

      const error = this.el.querySelector(".field-error") ||
        this.el.querySelector(".form-error") ||
        this.el.parentElement?.querySelector(".form-error")
      if (!error) return

      const field = error.closest(".form-field")
      const target = field?.querySelector("input, select, textarea") ||
        this.el.querySelector("input, select, textarea")
      window.requestAnimationFrame(() => target?.focus())
    },
    disconnected() {
      if (this.el.dataset.clearSensitive === "true") this.clearSensitiveInputs()
    },
    destroyed() {
      if (this.el.dataset.clearSensitive === "true") this.clearSensitiveInputs()
      this.el.removeEventListener("submit", this.submit)
      if (this.beforeUnload) {
        this.el.removeEventListener("input", this.markDirty)
        this.el.removeEventListener("change", this.markDirty)
        window.removeEventListener("beforeunload", this.beforeUnload)
        window.removeEventListener("phx:before-navigate", this.beforeNavigate)
      }
    },
    clearSensitiveInputs() {
      this.el.querySelectorAll("input[type='password']").forEach(input => { input.value = "" })
    },
  },
  LocalizedTime: {
    mounted() { this.localize() },
    updated() { this.localize() },
    localize() {
      const date = new Date(this.el.dateTime)
      if (Number.isNaN(date.getTime())) return

      this.el.textContent = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
      }).format(date)
    },
  },
  AppearanceControls: {
    mounted() {
      this.themeChanged = event => this.setSelected(event.detail?.theme)
      this.storageChanged = event => {
        if (event.key === "biot:theme") this.setSelected(event.newValue || "system")
      }

      window.addEventListener("biot-theme-changed", this.themeChanged)
      window.addEventListener("storage", this.storageChanged)
      this.setSelected(document.documentElement.dataset.themeSource || "system")
    },
    destroyed() {
      window.removeEventListener("biot-theme-changed", this.themeChanged)
      window.removeEventListener("storage", this.storageChanged)
    },
    setSelected(theme) {
      const selected = ["dark", "light", "system"].includes(theme) ? theme : "system"

      this.el.querySelectorAll("[data-theme-choice]").forEach(button => {
        const isSelected = button.dataset.themeChoice === selected
        button.setAttribute("aria-pressed", String(isSelected))
        button.classList.toggle("is-selected", isSelected)
      })
    },
  },
  GhosttyTerminal: {
    mounted() {
      this.closed = false
      this.websocket = null
      this.terminal = null
      this.fitAddon = null
      this.exitStatus = null
      this.reconnectAttempt = 0
      this.reconnectTimer = null
      this.maxReconnectAttempts = 5
      this.statusElement = document.getElementById("terminal-status")
      this.themeChanged = () => this.updateTerminalTheme()
      window.addEventListener("biot-theme-changed", this.themeChanged)
      this.dimensions = {cols: 80, rows: 24}
      this.setStatus("connecting…")
      this.openTerminal()
    },
    async openTerminal() {
      try {
        const {ghostty, Terminal, FitAddon} = await loadGhosttyWeb()
        if (this.closed) return

        this.el.replaceChildren()
        this.terminal = new Terminal({
          cols: this.dimensions.cols,
          rows: this.dimensions.rows,
          cursorBlink: true,
          fontFamily: '"Space Mono", ui-monospace, Menlo, monospace',
          fontSize: 14,
          ghostty,
          theme: this.terminalTheme(),
        })
        this.terminal.open(this.el)
        this.fitAddon = new FitAddon()
        this.terminal.loadAddon(this.fitAddon)
        this.terminal.onData(data => this.sendInput(data))
        this.terminal.onResize(({cols, rows}) => {
          this.dimensions = {cols, rows}
          this.sendResize()
        })
        this.fitAddon.fit()
        this.dimensions = this.fitAddon.proposeDimensions() || this.dimensions
        this.fitAddon.observeResize()
        this.terminal.focus()
        this.connectSocket()
      } catch (_error) {
        if (!this.closed) this.setStatus("closed · terminal unavailable")
      }
    },
    connectSocket() {
      const url = new URL(this.el.dataset.socketPath, window.location.href)
      url.protocol = window.location.protocol === "https:" ? "wss:" : "ws:"
      url.searchParams.set("term", "xterm-256color")
      url.searchParams.set("cols", String(this.dimensions.cols))
      url.searchParams.set("rows", String(this.dimensions.rows))

      this.websocket = new WebSocket(url)
      this.websocket.binaryType = "arraybuffer"
      this.websocket.addEventListener("open", () => {
        if (this.closed) return
        this.reconnectAttempt = 0
        this.setStatus("connected")
        this.sendResize()
        this.terminal?.focus()
      })
      this.websocket.addEventListener("message", event => this.receive(event))
      this.websocket.addEventListener("error", () => {
        if (!this.closed) this.setStatus("lost")
      })
      this.websocket.addEventListener("close", event => {
        if (this.closed) return

        this.setStatus(this.closeStatus(event))
        if (this.shouldReconnect(event)) this.scheduleReconnect()
      })
    },
    terminalTheme() {
      if (document.documentElement.dataset.theme === "light") {
        return {
          background: "#ffffff",
          foreground: "#0c3139",
          cursor: "#d55314",
          cursorAccent: "#ffffff",
          selectionBackground: "#c4e3cc",
        }
      }

      return {
        background: "#04181c",
        foreground: "#dcede1",
        cursor: "#fe771c",
        cursorAccent: "#04181c",
        selectionBackground: "#1b4a52",
      }
    },
    updateTerminalTheme() {
      this.terminal?.renderer?.setTheme(this.terminalTheme())
    },
    shouldReconnect(event) {
      const reason = event.reason.toLowerCase()
      return this.exitStatus === null &&
        !reason.includes("policy-closed") &&
        !reason.includes("expired") &&
        !reason.includes("malformed") &&
        (reason.includes("lost") || event.code === 1006)
    },
    scheduleReconnect() {
      if (this.reconnectTimer || this.reconnectAttempt >= this.maxReconnectAttempts) {
        if (this.reconnectAttempt >= this.maxReconnectAttempts) this.setStatus("lost")
        return
      }

      this.reconnectAttempt += 1
      const delay = Math.min(500 * 2 ** (this.reconnectAttempt - 1), 8_000)
      this.setStatus(`reconnecting… (${this.reconnectAttempt}/${this.maxReconnectAttempts})`)
      this.reconnectTimer = window.setTimeout(() => {
        this.reconnectTimer = null
        if (!this.closed) this.connectSocket()
      }, delay)
    },
    sendInput(data) {
      if (this.websocket?.readyState !== WebSocket.OPEN) return
      this.websocket.send(new TextEncoder().encode(data))
    },
    sendResize() {
      if (this.websocket?.readyState !== WebSocket.OPEN) return
      this.websocket.send(JSON.stringify({resize: this.dimensions}))
    },
    receive(event) {
      if (typeof event.data === "string") {
        try {
          const message = JSON.parse(event.data)
          if (Number.isInteger(message.exit) && message.exit >= 0 && message.exit <= 255) {
            this.exitStatus = message.exit
            this.setStatus(`closed · exit status ${message.exit}`)
          }
        } catch (_error) {
          this.setStatus("lost")
        }
        return
      }

      if (event.data instanceof ArrayBuffer) {
        this.terminal?.write(new Uint8Array(event.data))
      } else if (event.data instanceof Blob) {
        event.data.arrayBuffer().then(bytes => {
          if (!this.closed) this.terminal?.write(new Uint8Array(bytes))
        })
      }
    },
    closeStatus(event) {
      const reason = event.reason.toLowerCase()
      if (reason.includes("policy-closed")) return "policy-closed"
      if (reason.includes("expired")) return "expired"
      if (reason.includes("lost") || event.code === 1006) return "lost"
      if (reason.includes("malformed")) return "closed · malformed message"
      if (this.exitStatus !== null) return `closed · exit status ${this.exitStatus}`
      return "closed"
    },
    setStatus(status) {
      if (this.statusElement) this.statusElement.textContent = status
    },
    destroyed() {
      this.closed = true
      window.removeEventListener("biot-theme-changed", this.themeChanged)
      if (this.reconnectTimer) window.clearTimeout(this.reconnectTimer)
      if (this.websocket && this.websocket.readyState < WebSocket.CLOSING) {
        this.websocket.close(1000, "closed")
      }
      this.fitAddon?.dispose()
      this.terminal?.dispose()
    },
  },
}
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks,
})

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", event => keyDown = event.key)
    window.addEventListener("keyup", _event => keyDown = null)
    window.addEventListener("click", event => {
      if (keyDown === "c") {
        event.preventDefault()
        event.stopImmediatePropagation()
        reloader.openEditorAtCaller(event.target)
      } else if (keyDown === "d") {
        event.preventDefault()
        event.stopImmediatePropagation()
        reloader.openEditorAtDef(event.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
