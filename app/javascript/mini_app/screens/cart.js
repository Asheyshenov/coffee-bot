// Cart: lines with −/+ and remove, comment (up to 200 characters), total, checkout
// (POST /api/orders) with the MainButton "Оформить заказ · 450 сом"

import { h, button, fill } from "mini_app/dom"
import { formatMoney } from "mini_app/format"
import { errorMessage, serverNow } from "mini_app/api"
import { haptic, mainButton, showAlert, showConfirm, showPopup } from "mini_app/telegram"
import { MAX_QTY_PER_LINE } from "mini_app/store"
import { isOpen } from "mini_app/status"
import { itemEmoji } from "mini_app/screens/menu"

const COMMENT_MAX = 200
// An order created while the response got lost is still this fresh
const RECOVERY_WINDOW_MS = 3 * 60 * 1000

// sessionStorage can be off (private mode, some embedded browsers): the comment then
// lives only as long as the screen
const storage = {
  get(key) {
    try {
      return window.sessionStorage.getItem(key)
    } catch {
      return null
    }
  },
  set(key, value) {
    try {
      window.sessionStorage.setItem(key, value)
    } catch {
      // not kept
    }
  },
  remove(key) {
    try {
      window.sessionStorage.removeItem(key)
    } catch {
      // nothing kept
    }
  }
}

export function cartChangedText({ removed = [], repriced = [] }) {
  const parts = []
  if (removed.length) parts.push(`Больше нет в меню: ${removed.join(", ")}.`)
  if (repriced.length) parts.push(`Изменилась цена: ${repriced.join(", ")}.`)
  parts.push("Проверьте корзину и оформите заказ ещё раз.")
  return parts.join("\n")
}

export function cartScreen(ctx) {
  const { store, api } = ctx
  const money = (amount) => formatMoney(amount, store.state.shop?.shop?.currency)
  const storageKey = `mini_app:${ctx.config.botId}:comment`

  let checkingOut = false

  // === Layout ===
  const clearButton = button({ class: "ma-btn-text ma-btn-danger px-2", onclick: clearCart }, "Очистить")
  const header = h("header", { class: "ma-header" }, h("h1", { class: "ma-title" }, "Корзина"), clearButton)
  const changes = h("div", { class: "mt-3", hidden: true })
  const lines = h("div", { class: "ma-card ma-list mt-3" })
  const totalValue = h("span")
  const summary = h("div", { class: "ma-card mt-3" }, h("div", { class: "ma-total" }, h("span", {}, "Итого"), totalValue))

  const textarea = h("textarea", {
    id: "order-comment",
    class: "ma-textarea",
    maxlength: COMMENT_MAX,
    rows: 3,
    placeholder: "Например: без сахара, на овсяном молоке",
    "aria-describedby": "order-comment-counter",
    oninput: onCommentInput
  })
  const counter = h("div", { class: "ma-counter", id: "order-comment-counter" })
  const commentBlock = h("div", {},
    h("label", { class: "ma-label", for: "order-comment" }, "Комментарий к заказу"),
    h("div", { class: "ma-card" }, textarea, counter))

  const checkoutButton = mainButton.supported ? null : button({ class: "ma-btn mt-5", onclick: checkout })
  const content = h("div", {}, changes, lines, commentBlock, summary,
    h("p", { class: "ma-hint" }, "Оплата в O!Деньги. Заказ заберёте на стойке, когда он будет готов."),
    checkoutButton)

  const empty = h("div", { class: "ma-notice", hidden: true },
    h("div", { class: "ma-notice-emoji", "aria-hidden": "true" }, "🛒"),
    h("h2", { class: "ma-notice-title" }, "Корзина пуста"),
    h("p", { class: "ma-notice-text" }, "Выберите напитки и десерты в меню."),
    mainButton.supported ? null : button({ class: "ma-btn", onclick: () => ctx.back() }, "Перейти в меню"))

  const el = h("div", {}, header, content, empty)

  // === Comment: kept while the app is open, prefilled with the cart's (chat) comment ===
  textarea.value = (storage.get(storageKey) ?? store.state.cart.comment ?? "").slice(0, COMMENT_MAX)
  updateCounter()

  function onCommentInput() {
    storage.set(storageKey, textarea.value)
    updateCounter()
  }

  function updateCounter() {
    counter.textContent = `${textarea.value.length}/${COMMENT_MAX}`
  }

  // === Lines ===
  function render() {
    const cart = store.state.cart
    const hasItems = cart.items.length > 0
    content.hidden = !hasItems
    clearButton.hidden = !hasItems
    empty.hidden = hasItems
    if (!hasItems) changes.hidden = true

    const max = cart.max_qty_per_line || MAX_QTY_PER_LINE
    fill(lines, cart.items.map((line) => lineRow(line, max)))
    totalValue.textContent = money(cart.total)
    if (checkoutButton) {
      checkoutButton.textContent = checkoutText()
      checkoutButton.disabled = checkingOut
    }
    ctx.refresh(screen)
  }

  function lineRow(line, max) {
    const name = line.display_name || line.name
    const step = (delta) => () => {
      haptic.selection()
      store.cart.setQty(line.index, line.qty + delta)
    }

    return h("div", { class: "ma-row" },
      h("span", { class: "ma-row-emoji", "aria-hidden": "true" }, itemEmoji(store.menuItem(line.menu_item_id) || {})),
      h("div", { class: "ma-row-main" },
        h("div", { class: "ma-row-title" }, name),
        h("div", { class: "ma-row-sub tabular-nums" }, line.qty > 1 ? `${money(line.line_total)} · ${money(line.unit_price)}/шт.` : money(line.line_total)),
        button({ class: "mt-1 text-sm text-tg-destructive", "aria-label": `Удалить: ${name}`, onclick: () => removeLine(line) }, "Удалить")),
      h("div", { class: "ma-stepper", role: "group", "aria-label": `Количество: ${name}` },
        button({ class: "ma-icon-button", "aria-label": `Меньше: ${name}`, disabled: line.qty <= 1, onclick: step(-1) }, "−"),
        h("span", { class: "ma-stepper-value", "aria-live": "polite" }, String(line.qty)),
        button({ class: "ma-icon-button", "aria-label": `Больше: ${name}`, disabled: line.qty >= max, onclick: step(1) }, "+")))
  }

  function removeLine(line) {
    haptic.impact("light")
    store.cart.remove(line.index)
  }

  async function clearCart() {
    const ok = await showConfirm("Убрать всё из корзины?", { confirmText: "Очистить", cancelText: "Отмена", destructive: true })
    if (ok) store.cart.clear()
  }

  // A 409 cart_changed: what changed stays above the lines until the next checkout
  function showChanges(data) {
    fill(changes, h("div", { class: "ma-banner ma-banner-warning", role: "alert" },
      h("span", { class: "ma-banner-emoji", "aria-hidden": "true" }, "🔄"),
      h("span", { class: "min-w-0 flex-1 whitespace-pre-line text-sm" }, cartChangedText(data))))
    changes.hidden = false
  }

  // === Checkout ===
  function checkoutText() {
    const cart = store.state.cart
    return `Оформить заказ · ${money(cart.total)}`
  }

  async function checkout() {
    // The server does not guard against a double checkout: one request at a time
    if (checkingOut || !store.state.cart.items.length) return

    checkingOut = true
    textarea.blur()
    render()
    try {
      await store.cart.settle()
      if (!store.state.cart.items.length) return

      const order = await api.createOrder(textarea.value.trim())
      done(order)
    } catch (error) {
      await checkoutFailed(error)
    } finally {
      checkingOut = false
      if (screen.active) render()
    }
  }

  function done(order) {
    storage.remove(storageKey)
    store.setCart(null)
    store.upsertOrder(order)
    haptic.notify("success")
    ctx.replace("order", { order, fresh: true })
  }

  async function checkoutFailed(error) {
    if (error.code === "cart_changed") {
      haptic.notify("warning")
      store.setCart(error.data?.cart)
      showChanges(error.data || {})
      window.scrollTo({ top: 0, behavior: "smooth" })
      await showPopup({ title: "Корзина обновилась", message: cartChangedText(error.data || {}), buttons: [ { type: "ok" } ] })
    } else if (error.code === "empty_cart") {
      await ctx.reloadCart()
      ctx.toast(errorMessage(error))
    } else if (error.code === "invoice_failed") {
      haptic.notify("error")
      await showAlert(errorMessage(error), "Оплата недоступна")
    } else if (error.offline && await recoverLostOrder()) {
      // the order was created, the answer got lost on the way
    } else {
      ctx.fail(error)
    }
  }

  // After a timeout the order may exist anyway: the server empties the cart once it does
  async function recoverLostOrder() {
    try {
      const cart = await api.cart()
      if (cart.items.length) return false

      const { orders } = await api.orders()
      const order = orders.find((o) => isOpen(o) && serverNow() - new Date(o.created_at).getTime() < RECOVERY_WINDOW_MS)
      if (!order) return false

      done(order)
      return true
    } catch {
      return false
    }
  }

  const screen = {
    el,
    active: false,

    main() {
      if (!store.state.cart.items.length) return { text: "Перейти в меню", onClick: () => ctx.back() }
      return { text: checkoutText(), onClick: checkout, progress: checkingOut }
    },

    enter() {
      screen.active = true
      render()
      // The chat bot shares the cart: show what is there now
      ctx.reloadCart()
    },

    leave() {
      screen.active = false
    },

    update(what) {
      if (what === "cart" && screen.active) render()
    }
  }
  return screen
}
