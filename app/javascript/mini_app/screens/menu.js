// Menu: shop name, open orders, category chips and the item cards of every category

import { h, button, fill } from "mini_app/dom"
import { formatMoney, categoryEmoji } from "mini_app/format"
import { haptic } from "mini_app/telegram"
import { isOpen, statusInfo } from "mini_app/status"

// Groups the items by category, in menu order
export function menuGroups(shop) {
  const groups = new Map((shop?.categories || []).map((c) => [ c.name, { name: c.name, emoji: categoryEmoji(c.name), items: [] } ]))
  const other = { name: "Другое", emoji: "🍽️", items: [] }
  for (const item of shop?.items || []) (groups.get(item.category) || other).items.push(item)
  return [ ...groups.values(), other ].filter((group) => group.items.length > 0)
}

export function itemEmoji(item) {
  return categoryEmoji(item?.category || "")
}

// "от 130 сом" when the sizes cost differently
export function priceText(item, currency) {
  const prices = (item.sizes || []).map((s) => s.price)
  if (new Set(prices).size > 1) return `от ${formatMoney(Math.min(...prices), currency)}`
  return formatMoney(prices.length ? prices[0] : item.price, currency)
}

export function menuScreen(ctx) {
  const { store } = ctx
  const currency = () => store.state.shop?.shop?.currency
  const money = (amount) => formatMoney(amount, currency())

  const title = h("h1", { class: "ma-title" })
  const header = h("header", { class: "ma-header" },
    title,
    button({ class: "ma-pill-button", onclick: () => ctx.open("orders") }, h("span", { "aria-hidden": "true" }, "📦"), "Мои заказы"))
  const banners = h("div", { class: "mt-3 flex flex-col gap-2 empty:hidden" })
  const chips = h("nav", { class: "ma-chips", "aria-label": "Категории" })
  const sections = h("div")
  const el = h("div", {}, header, banners, chips, sections)

  let chipButtons = []
  let sectionEls = []
  let cards = new Map() // item id -> { card, badge, label }
  let activeChip = -1
  let spyPausedUntil = 0
  let ticking = false

  function build() {
    const shop = store.state.shop
    title.textContent = shop?.shop?.name || ctx.config.shopName || "Меню"
    const groups = menuGroups(shop)
    cards = new Map()

    if (!groups.length) {
      chips.hidden = true
      fill(sections, h("div", { class: "ma-notice" },
        h("div", { class: "ma-notice-emoji", "aria-hidden": "true" }, "🫙"),
        h("h2", { class: "ma-notice-title" }, "Меню пока пустое"),
        h("p", { class: "ma-notice-text" }, "Загляните чуть позже.")))
      sectionEls = []
      chipButtons = []
      return
    }

    chipButtons = groups.map((group, i) => button({ class: "ma-chip", "aria-current": "false", onclick: () => jumpTo(i) }, group.name))
    fill(chips, chipButtons)
    chips.hidden = groups.length < 2

    sectionEls = groups.map((group, i) => h("section", { class: "ma-section", "aria-labelledby": `category-${i}` },
      h("h2", { class: "ma-section-title", id: `category-${i}` }, group.name),
      h("div", { class: "ma-grid" }, group.items.map((item) => itemCard(item, group.emoji)))))
    fill(sections, sectionEls)
    activeChip = -1
    setActiveChip(0)
    updateBadges()
  }

  function itemCard(item, emoji) {
    const label = `${item.name}, ${priceText(item, currency())}`
    const badge = h("span", { class: "ma-badge", hidden: true, "aria-hidden": "true" })
    const card = button({ class: "ma-item", "aria-label": label, onclick: () => ctx.openItem(item) },
      h("span", { class: "ma-item-tile", "aria-hidden": "true" }, emoji),
      h("span", { class: "ma-item-name" }, item.name),
      h("span", { class: "ma-item-price" }, priceText(item, currency())),
      h("span", { class: "ma-item-plus", "aria-hidden": "true" }, "+"),
      badge)
    cards.set(item.id, { card, badge, label })
    return card
  }

  // Quantity of each item already in the cart, on its card
  function updateBadges() {
    const inCart = new Map()
    for (const line of store.state.cart.items) inCart.set(line.menu_item_id, (inCart.get(line.menu_item_id) || 0) + line.qty)
    for (const [ id, { card, badge, label } ] of cards) {
      const qty = inCart.get(id) || 0
      badge.hidden = qty === 0
      badge.textContent = String(qty)
      card.setAttribute("aria-label", qty ? `${label}, в корзине ${qty}` : label)
    }
  }

  // Unpaid, paid and in-progress orders: one tap back to their status
  function renderBanners() {
    const open = (store.state.orders || []).filter(isOpen).slice(0, 3)
    fill(banners, open.map((order) => {
      const info = statusInfo(order)
      return button({ class: "ma-banner", onclick: () => ctx.open("order", { order }) },
        h("span", { class: "ma-banner-emoji", "aria-hidden": "true" }, info.emoji),
        h("span", { class: "min-w-0 flex-1" },
          h("span", { class: "block font-semibold" }, `Заказ #${order.id} · ${money(order.total)}`),
          h("span", { class: "block text-sm text-tg-hint" }, info.title)),
        h("span", { class: "ma-chevron", "aria-hidden": "true" }, "›"))
    }))
  }

  // === Category chips follow the scroll ===

  function jumpTo(index) {
    const section = sectionEls[index]
    if (!section) return

    haptic.selection()
    spyPausedUntil = Date.now() + 700
    setActiveChip(index)
    const top = index === 0 ? 0 : section.getBoundingClientRect().top + window.scrollY - chips.offsetHeight + 1
    window.scrollTo({ top, behavior: "smooth" })
  }

  function setActiveChip(index) {
    if (index === activeChip || !chipButtons[index]) return

    activeChip = index
    chipButtons.forEach((chip, i) => chip.setAttribute("aria-current", String(i === index)))
    const chip = chipButtons[index]
    const left = chip.offsetLeft - (chips.clientWidth - chip.offsetWidth) / 2
    chips.scrollTo?.({ left: Math.max(0, left), behavior: "smooth" })
  }

  function spy() {
    ticking = false
    if (Date.now() < spyPausedUntil || !sectionEls.length) return

    const line = chips.getBoundingClientRect().bottom + 16
    let index = 0
    sectionEls.forEach((section, i) => {
      if (section.getBoundingClientRect().top <= line) index = i
    })
    const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4
    setActiveChip(atBottom && window.scrollY > 0 ? sectionEls.length - 1 : index)
  }

  function onScroll() {
    if (ticking) return
    ticking = true
    requestAnimationFrame(spy)
  }

  build()

  const screen = {
    el,

    main() {
      const cart = store.state.cart
      if (!cart.count) return null
      return { text: `Корзина · ${cart.count} · ${money(cart.total)}`, onClick: () => ctx.open("cart") }
    },

    enter() {
      renderBanners()
      updateBadges()
      window.addEventListener("scroll", onScroll, { passive: true })
      ctx.refreshOrders()
    },

    leave() {
      window.removeEventListener("scroll", onScroll)
    },

    update(what) {
      if (what === "shop") build()
      if (what === "cart") updateBadges()
      if (what === "orders") renderBanners()
    }
  }
  return screen
}
