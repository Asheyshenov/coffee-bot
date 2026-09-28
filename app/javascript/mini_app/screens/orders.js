// "Мои заказы": the customer's latest 10 orders (GET /api/orders)

import { h, button, fill } from "mini_app/dom"
import { formatDateTime, formatMoney } from "mini_app/format"
import { statusInfo, toneClass } from "mini_app/status"

export function ordersScreen(ctx) {
  const { api, store } = ctx
  const money = (amount) => formatMoney(amount, store.state.shop?.shop?.currency)

  const list = h("div", { class: "mt-3 flex flex-col gap-2" })
  const el = h("div", {}, h("header", { class: "ma-header" }, h("h1", { class: "ma-title" }, "Мои заказы")), list)
  let loaded = false

  function render() {
    const orders = store.state.orders
    if (!orders) {
      fill(list, h("div", { class: "ma-notice" }, h("div", { class: "ma-spinner", role: "status", "aria-label": "Загружаем заказы" })))
      return
    }
    if (!orders.length) {
      fill(list, h("div", { class: "ma-notice" },
        h("div", { class: "ma-notice-emoji", "aria-hidden": "true" }, "🧾"),
        h("h2", { class: "ma-notice-title" }, "Заказов пока нет"),
        h("p", { class: "ma-notice-text" }, "Здесь появятся ваши заказы и их статус.")))
      return
    }
    fill(list, orders.map(orderCard))
  }

  function orderCard(order) {
    const info = statusInfo(order)
    const items = (order.items || []).map((item) => (item.qty > 1 ? `${item.name} × ${item.qty}` : item.name)).join(", ")
    return button({ class: "ma-card ma-row", onclick: () => ctx.open("order", { order }) },
      h("div", { class: "ma-row-main" },
        h("div", { class: "flex flex-wrap items-center gap-2" },
          h("span", { class: "ma-row-title" }, `#${order.id}`),
          h("span", { class: `ma-status-pill ${toneClass(info.tone)}` }, info.short)),
        h("div", { class: "ma-row-sub mt-1 truncate" }, items),
        h("div", { class: "ma-row-sub" }, formatDateTime(order.created_at))),
      h("div", { class: "ma-row-end" }, money(order.total)),
      h("span", { class: "ma-chevron", "aria-hidden": "true" }, "›"))
  }

  async function load() {
    try {
      const { orders } = await api.orders()
      loaded = true
      store.setOrders(orders)
    } catch (error) {
      ctx.fail(error)
      if (!store.state.orders) {
        fill(list, h("div", { class: "ma-notice" },
          h("h2", { class: "ma-notice-title" }, "Не удалось загрузить заказы"),
          button({ class: "ma-btn", onclick: () => { render(); load() } }, "Повторить")))
      }
    }
  }

  const screen = {
    el,
    active: false,
    main: () => null,

    enter() {
      screen.active = true
      render()
      load()
    },

    leave() {
      screen.active = false
    },

    resume() {
      if (screen.active && loaded) load()
    },

    update(what) {
      if (what === "orders" && screen.active) render()
    }
  }
  return screen
}
