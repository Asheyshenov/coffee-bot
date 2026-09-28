// Customer Mini App of a coffee shop's bot: menu -> item -> cart -> checkout -> payment ->
// order status, and "Мои заказы". Page: app/views/mini_app/pages/show.html.erb,
// API: plans/mini-app-api.md. Vanilla ES modules through importmap, no build step.
//
// Screens are objects { el, main(), enter(), leave(), update(what), resume(), destroy() }:
// main() describes the Telegram MainButton of the screen; the BackButton goes back.

import { closeApp, haptic, inTelegram, initData, initTelegram, mainButton, backButton, onEvent } from "mini_app/telegram"
import { ApiError, createApi, errorMessage } from "mini_app/api"
import { createStore } from "mini_app/store"
import { h, button } from "mini_app/dom"
import { menuScreen } from "mini_app/screens/menu"
import { itemSheet } from "mini_app/screens/item"
import { cartScreen } from "mini_app/screens/cart"
import { orderScreen } from "mini_app/screens/order"
import { ordersScreen } from "mini_app/screens/orders"
import { noticeScreen } from "mini_app/screens/notice"

const SCREENS = { cart: cartScreen, order: orderScreen, orders: ordersScreen }
const TOAST_MS = 2800

const root = document.getElementById("mini-app")
if (root?.dataset.page === "app") start(root)
else startStaticPage()

// Unknown bot / shop not serving: the server rendered the message
function startStaticPage() {
  initTelegram()
  if (inTelegram) mainButton.set({ text: "Закрыть", onClick: closeApp })
}

function start(root) {
  const config = {
    botId: root.dataset.botId,
    apiBase: root.dataset.apiBase,
    shopName: root.dataset.shopName,
    botUsername: root.dataset.botUsername
  }

  initTelegram()
  const toasts = h("div", { class: "ma-toasts", "aria-live": "polite" })
  document.body.append(toasts)
  const nav = createNavigator(root)

  if (!inTelegram) {
    nav.fatal(noticeScreen(outsideTelegramNotice(config)))
    return
  }

  const api = createApi(config.apiBase, initData)
  const store = createStore(api, { onError: fail })
  store.subscribe((what) => nav.update(what))

  const ctx = {
    config,
    api,
    store,
    open: (name, params = {}) => nav.push(SCREENS[name](ctx, params)),
    replace: (name, params = {}) => nav.replace(SCREENS[name](ctx, params)),
    back: () => nav.back(),
    home: () => nav.home(),
    openItem: (item) => nav.openSheet(itemSheet(ctx, item)),
    closeSheet: () => nav.closeSheet(),
    // Re-apply the MainButton of a screen after its state changed (if it is on top)
    refresh: (screen) => nav.refresh(screen),
    toast,
    fail,
    reloadShop,
    reloadCart,
    refreshOrders
  }

  // 401 / shop closed end the session; everything else is a short message
  function fail(error) {
    if (error?.status === 401) return nav.fatal(noticeScreen(sessionExpiredNotice()))
    if (error?.code === "shop_unavailable") return nav.fatal(noticeScreen(shopClosedNotice(config)))

    if (!(error instanceof ApiError)) console.error(error)
    haptic.notify("error")
    toast(errorMessage(error))
  }

  function toast(message) {
    const el = h("div", { class: "ma-toast" }, message)
    toasts.append(el)
    while (toasts.children.length > 2) toasts.firstElementChild.remove()
    requestAnimationFrame(() => el.classList.add("is-visible"))
    setTimeout(() => {
      el.classList.remove("is-visible")
      setTimeout(() => el.remove(), 250)
    }, TOAST_MS)
  }

  async function load() {
    try {
      const [ shop, cart ] = await Promise.all([ api.shop(), api.cart() ])
      store.setShop(shop)
      store.setCart(cart)
    } catch (error) {
      if (error?.status === 401 || error?.code === "shop_unavailable") return fail(error)
      if (error?.status === 404) return nav.fatal(noticeScreen(notFoundNotice()))

      nav.reset(noticeScreen({
        emoji: "📡",
        title: "Не удалось загрузить меню",
        text: errorMessage(error),
        action: { text: "Повторить", onClick: retry }
      }))
      return
    }

    nav.reset(menuScreen(ctx))
    // /app/:bot_id?order=42 opens that order (e.g. from a bot message)
    const orderId = new URLSearchParams(window.location.search).get("order")
    if (/^\d+$/.test(orderId || "")) ctx.open("order", { id: Number(orderId) })
  }

  function retry() {
    nav.reset(noticeScreen({ emoji: "☕", title: "Загружаем меню…" }))
    load()
  }

  function reloadShop() {
    return api.shop().then((shop) => store.setShop(shop)).catch(() => undefined)
  }

  // Only when no cart change is on its way, and only if nothing changed the cart meanwhile
  function reloadCart() {
    if (!store.cart.idle) return Promise.resolve()
    const version = store.state.cartVersion
    return api.cart()
      .then((cart) => {
        if (store.cart.idle && store.state.cartVersion === version) store.setCart(cart)
      })
      .catch((error) => {
        if (error?.status === 401) fail(error)
      })
  }

  let ordersRequest = null
  function refreshOrders() {
    ordersRequest ||= api.orders()
      .then(({ orders }) => store.setOrders(orders))
      .catch((error) => {
        if (error?.status === 401) fail(error)
      })
      .finally(() => {
        ordersRequest = null
      })
    return ordersRequest
  }

  // Back from the payment app or the chat: refresh the order status and the cart
  // (the chat bot shares the cart)
  let resumedAt = 0
  function resume() {
    if (nav.isFatal() || Date.now() - resumedAt < 1000) return
    resumedAt = Date.now()
    nav.resume()
    reloadCart()
  }
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) resume()
  })
  onEvent("activated", resume)
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") nav.back()
  })

  load()
}

// Screen stack + the item sheet, and the Telegram MainButton / BackButton that go with them
function createNavigator(root) {
  let stack = []
  let sheet = null
  let fatal = false
  // Telegram before 6.1 has no BackButton
  const pageBack = backButton.supported ? null : button({ class: "ma-pill-button mb-3", onclick: () => nav.back() }, "‹ Назад")

  const top = () => stack[stack.length - 1] || null
  const active = () => sheet || top()

  function show(screen, scrollY = 0) {
    root.replaceChildren(...(pageBack && stack.length > 1 ? [ pageBack, screen.el ] : [ screen.el ]))
    screen.enter?.()
    window.scrollTo(0, scrollY)
    chrome()
  }

  function hide(screen) {
    screen.scrollY = window.scrollY
    screen.leave?.()
  }

  function drop(screen) {
    screen.leave?.()
    screen.destroy?.()
  }

  function dropSheet() {
    if (!sheet) return
    const current = sheet
    sheet = null
    document.documentElement.classList.remove("ma-sheet-open")
    current.close()
  }

  function chrome() {
    const current = active()
    if (!current) return

    const main = current.main?.()
    if (main) mainButton.set(main)
    else mainButton.hide()
    backButton.set(sheet || stack.length > 1 ? nav.back : null)
  }

  const nav = {
    isFatal: () => fatal,

    push(screen) {
      if (fatal) return
      dropSheet()
      if (top()) hide(top())
      stack.push(screen)
      show(screen)
    },

    replace(screen) {
      if (fatal) return
      dropSheet()
      if (top()) drop(stack.pop())
      stack.push(screen)
      show(screen)
    },

    reset(screen) {
      if (fatal) return
      dropSheet()
      stack.forEach(drop)
      stack = [ screen ]
      show(screen)
    },

    // The session can't go on (401, shop closed, outside Telegram)
    fatal(screen) {
      nav.reset(screen)
      fatal = true
    },

    back() {
      if (sheet) return nav.closeSheet()
      if (stack.length < 2) return

      drop(stack.pop())
      const previous = top()
      show(previous, previous.scrollY || 0)
    },

    home() {
      dropSheet()
      while (stack.length > 1) drop(stack.pop())
      if (top()) show(top())
    },

    openSheet(next) {
      if (fatal) return
      dropSheet()
      sheet = next
      document.documentElement.classList.add("ma-sheet-open")
      document.body.append(next.el)
      next.open()
      chrome()
    },

    closeSheet() {
      dropSheet()
      chrome()
    },

    refresh(screen) {
      if (active() === screen) chrome()
    },

    update(what) {
      stack.forEach((screen) => screen.update?.(what))
      sheet?.update?.(what)
      chrome()
    },

    resume() {
      top()?.resume?.()
    }
  }
  return nav
}

function outsideTelegramNotice({ botUsername }) {
  return {
    emoji: "📱",
    title: "Откройте меню через бота в Telegram",
    text: botUsername
      ? `Меню работает внутри Telegram: откройте @${botUsername} и нажмите «☕ Меню».`
      : "Меню работает внутри Telegram: откройте бота кофейни и нажмите «☕ Меню».",
    link: botUsername ? { text: `Открыть @${botUsername}`, href: `https://t.me/${encodeURIComponent(botUsername)}` } : null
  }
}

function sessionExpiredNotice() {
  return {
    emoji: "🔒",
    title: "Сессия устарела",
    text: "Закройте меню и откройте его снова через бота.",
    action: { text: "Закрыть", onClick: closeApp }
  }
}

function shopClosedNotice({ shopName }) {
  return {
    emoji: "☕",
    title: `${shopName || "Кофейня"} временно не принимает заказы`,
    text: "Загляните чуть позже: мы скоро снова будем готовить для вас.",
    action: { text: "Закрыть", onClick: closeApp }
  }
}

function notFoundNotice() {
  return {
    emoji: "🔍",
    title: "Меню не найдено",
    text: "Этот бот больше не принимает заказы. Откройте меню заново из чата с кофейней.",
    action: { text: "Закрыть", onClick: closeApp }
  }
}
