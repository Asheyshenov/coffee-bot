// Item sheet: size (S / M / L with prices), quantity 1..20, MainButton "Добавить · 150 сом"

import { h, button } from "mini_app/dom"
import { formatMoney } from "mini_app/format"
import { haptic, mainButton } from "mini_app/telegram"
import { MAX_QTY_PER_LINE } from "mini_app/store"
import { itemEmoji } from "mini_app/screens/menu"

export function itemSheet(ctx, item) {
  const { store } = ctx
  const money = (amount) => formatMoney(amount, store.state.shop?.shop?.currency)
  const sizes = item.sizes || []
  const max = store.state.cart.max_qty_per_line || MAX_QTY_PER_LINE

  let size = sizes.find((s) => s.size === item.default_size)?.size || sizes[0]?.size || null
  let qty = 1
  let adding = false

  const unitPrice = () => sizes.find((s) => s.size === size)?.price ?? item.price
  const titleId = `item-${item.id}-title`

  // === Sizes ===
  const segments = sizes.map((option) => button({
    class: "ma-segment",
    role: "radio",
    "aria-checked": String(option.size === size),
    "aria-label": `${option.label}, ${money(option.price)}`,
    onclick: () => selectSize(option.size)
  }, h("span", { class: "ma-segment-label" }, option.label), h("span", { class: "ma-segment-price" }, money(option.price))))

  function selectSize(value) {
    if (value === size) return
    size = value
    haptic.selection()
    segments.forEach((segment, i) => segment.setAttribute("aria-checked", String(sizes[i].size === size)))
    refresh()
  }

  // === Quantity ===
  const qtyValue = h("span", { class: "ma-stepper-value", "aria-live": "polite" }, "1")
  const minus = button({ class: "ma-icon-button", "aria-label": "Уменьшить количество", onclick: () => setQty(qty - 1) }, "−")
  const plus = button({ class: "ma-icon-button", "aria-label": "Увеличить количество", onclick: () => setQty(qty + 1) }, "+")

  function setQty(value) {
    const next = Math.min(Math.max(1, value), max)
    if (next === qty) return
    qty = next
    haptic.selection()
    refresh()
  }

  // Without a Telegram MainButton the sheet has its own
  const addButton = mainButton.supported ? null : button({ class: "ma-btn mt-5", onclick: add })
  const inCartNote = h("p", { class: "ma-hint text-center", hidden: true })

  const panel = h("div", { class: "ma-sheet", role: "dialog", "aria-modal": "true", "aria-labelledby": titleId, tabindex: "-1" },
    h("div", { class: "ma-sheet-handle", "aria-hidden": "true" }),
    button({ class: "ma-sheet-close", "aria-label": "Закрыть", onclick: () => ctx.closeSheet() }, "✕"),
    h("div", { class: "ma-sheet-tile", "aria-hidden": "true" }, itemEmoji(item)),
    h("h2", { id: titleId, class: "mt-4 text-2xl font-bold leading-tight" }, item.name),
    item.description ? h("p", { class: "mt-1 text-tg-hint" }, item.description) : null,
    sizes.length ? h("div", { class: "mt-5" },
      h("div", { class: "mb-2 font-semibold", id: `${titleId}-size` }, "Размер"),
      h("div", { class: "ma-segmented", role: "radiogroup", "aria-labelledby": `${titleId}-size` }, segments)) : null,
    h("div", { class: "mt-5 flex items-center justify-between gap-4" },
      h("span", { class: "font-semibold", id: `${titleId}-qty` }, "Количество"),
      h("div", { class: "ma-stepper ma-stepper-lg", role: "group", "aria-labelledby": `${titleId}-qty` }, minus, qtyValue, plus)),
    inCartNote,
    addButton)
  const backdrop = h("div", { class: "ma-sheet-backdrop", "aria-hidden": "true", onclick: () => ctx.closeSheet() })
  const el = h("div", {}, backdrop, panel)

  function lineOf(cart) {
    return cart.items.find((line) => line.menu_item_id === item.id && (line.size || null) === (size || null))
  }

  function refresh() {
    qtyValue.textContent = String(qty)
    minus.disabled = qty <= 1
    plus.disabled = qty >= max
    const line = lineOf(store.state.cart)
    inCartNote.hidden = !line
    if (line) inCartNote.textContent = `Уже в корзине: ${line.qty} шт.`
    if (addButton) {
      addButton.textContent = addText()
      addButton.disabled = adding
    }
    ctx.refresh(sheet)
  }

  function addText() {
    return `Добавить · ${money(unitPrice() * qty)}`
  }

  async function add() {
    if (adding) return
    adding = true
    refresh()
    const before = lineOf(store.state.cart)?.qty || 0
    try {
      const cart = await store.cart.add(item.id, size, qty)
      haptic.impact("light")
      const line = cart && lineOf(cart)
      ctx.closeSheet()
      if (line && line.qty - before < qty) ctx.toast(`В корзине ${line.qty} шт. «${line.display_name || item.name}»: больше в одну позицию нельзя`)
      else if (line) ctx.toast(`«${line.display_name || item.name}» в корзине`)
    } catch (error) {
      ctx.fail(error)
      if (error.code === "item_unavailable") {
        ctx.closeSheet()
        ctx.reloadShop()
      }
    } finally {
      adding = false
      if (sheet.isOpen) refresh()
    }
  }

  const sheet = {
    el,
    isOpen: false,

    main() {
      return { text: addText(), onClick: add, progress: adding }
    },

    open() {
      sheet.isOpen = true
      refresh()
      requestAnimationFrame(() => {
        backdrop.classList.add("is-open")
        panel.classList.add("is-open")
        panel.focus({ preventScroll: true })
      })
    },

    close() {
      sheet.isOpen = false
      backdrop.classList.remove("is-open")
      panel.classList.remove("is-open")
      setTimeout(() => el.remove(), 280)
    },

    update(what) {
      if (what === "cart" && sheet.isOpen) refresh()
    }
  }
  return sheet
}
