// Thin wrapper around Telegram.WebApp (https://core.telegram.org/bots/webapps).
// Every call checks that the client supports it: old Telegram versions and a normal
// browser must not break the app.

export const webApp = window.Telegram?.WebApp || null

// Mini Apps opened from an inline / menu button carry signed initData; without it
// (a normal browser, a keyboard button) the API can't tell who the customer is
export const initData = webApp?.initData || ""
export const inTelegram = Boolean(initData)

export function versionAtLeast(version) {
  try {
    return Boolean(webApp?.isVersionAtLeast?.(version))
  } catch {
    return false
  }
}

function safely(fn) {
  try {
    return fn()
  } catch (error) {
    console.warn("Telegram.WebApp call failed", error)
    return undefined
  }
}

export function initTelegram() {
  applyColorScheme()
  if (!webApp) return

  safely(() => webApp.ready())
  safely(() => webApp.expand())
  if (versionAtLeast("6.1")) {
    safely(() => webApp.setHeaderColor("secondary_bg_color"))
    safely(() => webApp.setBackgroundColor("secondary_bg_color"))
  }
  if (versionAtLeast("7.10")) safely(() => webApp.setBottomBarColor("secondary_bg_color"))

  safely(() => webApp.onEvent("themeChanged", () => {
    applyColorScheme()
    mainButton.restyle()
  }))
}

// Fallback colours in CSS follow the scheme of the Telegram theme
function applyColorScheme() {
  const scheme = webApp?.colorScheme
  if (scheme) document.documentElement.dataset.colorScheme = scheme
}

export function onEvent(name, handler) {
  if (webApp) safely(() => webApp.onEvent(name, handler))
}

// === MainButton: one handler at a time, ignores taps while an action runs ===

let mainState = null
let mainClick = null
let mainSent = null // last params sent: polling redraws must not restart the shine / flicker

export const mainButton = {
  get supported() {
    return Boolean(webApp?.MainButton)
  },

  // { text, onClick, disabled, progress, shine }
  set(state) {
    const button = webApp?.MainButton
    if (!button) return

    mainState = state
    if (!mainClick) {
      mainClick = () => {
        if (!mainState || mainState.disabled || mainState.progress) return
        mainState.onClick?.()
      }
      safely(() => button.onClick(mainClick))
    }
    this.restyle()
  },

  // Keep the same action, show / hide the spinner (e.g. while POST /orders runs)
  progress(on) {
    if (!mainState) return
    mainState = { ...mainState, progress: on }
    this.restyle()
  },

  hide() {
    mainState = null
    mainSent = null
    const button = webApp?.MainButton
    if (!button) return
    safely(() => {
      button.hideProgress()
      button.hide()
    })
  },

  restyle() {
    const button = webApp?.MainButton
    if (!button || !mainState) return

    const theme = webApp.themeParams || {}
    const disabled = Boolean(mainState.disabled)
    const params = {
      text: String(mainState.text || "").slice(0, 64),
      is_active: !disabled,
      is_visible: true,
      // Not every client greys out an inactive button: do it here
      color: disabled ? (theme.hint_color || "#a7a7ad") : (theme.button_color || "#2481cc"),
      text_color: theme.button_text_color || "#ffffff"
    }
    if (versionAtLeast("7.10")) params.has_shine_effect = Boolean(mainState.shine) && !disabled

    const sent = JSON.stringify({ ...params, progress: Boolean(mainState.progress) })
    if (sent === mainSent) return
    mainSent = sent

    safely(() => {
      button.setParams(params)
      if (mainState.progress) button.showProgress(false)
      else button.hideProgress()
    })
  }
}

// === BackButton (6.1+); the app shows its own back button without it ===

let backClick = null

export const backButton = {
  get supported() {
    return Boolean(webApp?.BackButton) && versionAtLeast("6.1")
  },

  set(handler) {
    if (!this.supported) return

    const button = webApp.BackButton
    safely(() => {
      if (backClick) button.offClick(backClick)
      backClick = handler
      if (handler) {
        button.onClick(handler)
        button.show()
      } else {
        button.hide()
      }
    })
  }
}

// === Haptics (6.1+) ===

export const haptic = {
  impact(style = "light") {
    if (versionAtLeast("6.1")) safely(() => webApp.HapticFeedback.impactOccurred(style))
  },
  notify(type) {
    if (versionAtLeast("6.1")) safely(() => webApp.HapticFeedback.notificationOccurred(type))
  },
  selection() {
    if (versionAtLeast("6.1")) safely(() => webApp.HapticFeedback.selectionChanged())
  }
}

// === Popups (6.2+, browser dialogs before) ===

let popupOpen = false

// @return Promise<string|null> id of the pressed button
export function showPopup({ title, message, buttons = [ { type: "ok" } ] }) {
  const text = String(message || "").slice(0, 256)
  if (!versionAtLeast("6.2")) {
    const confirmed = buttons.length > 1 ? window.confirm(text) : (window.alert(text), true)
    const primary = buttons.find((b) => b.type !== "cancel" && b.type !== "close")
    return Promise.resolve(confirmed ? (primary?.id ?? "ok") : null)
  }
  // Telegram throws while another popup is open
  if (popupOpen) return Promise.resolve(null)

  return new Promise((resolve) => {
    popupOpen = true
    const done = (id) => {
      popupOpen = false
      resolve(id || null)
    }
    const params = { message: text, buttons: buttons.map((b) => ({ ...b, text: b.text?.slice(0, 64) })) }
    if (title) params.title = String(title).slice(0, 64)
    try {
      webApp.showPopup(params, done)
    } catch (error) {
      console.warn("showPopup failed", error)
      done(null)
    }
  })
}

export function showAlert(message, title) {
  return showPopup({ title, message, buttons: [ { type: "ok" } ] }).then(() => undefined)
}

// @return Promise<boolean>
export function showConfirm(message, { title, confirmText = "Да", cancelText = "Нет", destructive = false } = {}) {
  return showPopup({
    title,
    message,
    buttons: [
      { id: "cancel", type: "default", text: cancelText },
      { id: "confirm", type: destructive ? "destructive" : "default", text: confirmText }
    ]
  }).then((id) => id === "confirm")
}

// === Links and closing ===

// Opens outside Telegram (payment apps, the O!Dengi page). Must follow a user tap.
export function openLink(url) {
  if (!url) return
  if (webApp?.openLink) safely(() => webApp.openLink(url))
  else window.open(url, "_blank", "noopener")
}

export function closeApp() {
  if (webApp) safely(() => webApp.close())
}
