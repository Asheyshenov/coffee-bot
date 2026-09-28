// Order: payment (amount, "Оплатить в O!Деньги", QR, countdown, cancel) while the invoice
// is open, then the status. Polls GET /api/orders/:id every 3 s while the order is open.

import { h, button, fill } from "mini_app/dom"
import { formatCountdown, formatDateTime, formatMoney } from "mini_app/format"
import { serverNow } from "mini_app/api"
import { haptic, mainButton, openLink, showAlert, showConfirm } from "mini_app/telegram"
import { STEPS, isOpen, statusInfo, toneClass } from "mini_app/status"

const POLL_MS = 3000
const MAX_BACKOFF_MS = 30_000

const CANCEL_OUTCOMES = {
  cancelled_locally: "Заказ отменён, но счёт не удалось отменить в платёжной системе. Пожалуйста, не оплачивайте его.",
  paid_now: "Заказ уже оплачен и стоит в очереди. Для отмены обратитесь к баристе.",
  already_paid: "Заказ уже оплачен и стоит в очереди. Для отмены обратитесь к баристе.",
  in_progress: "Заказ уже готовится. Для отмены обратитесь к баристе.",
  payment_problem: "Оплата не принята: сумма платежа не совпадает с суммой заказа. Бариста проверит платёж и свяжется с вами.",
  not_cancellable: "Этот заказ уже нельзя отменить."
}

// fresh: the order was just returned by the API (checkout); otherwise it is fetched at once
export function orderScreen(ctx, { id, order: initial, fresh = false }) {
  const { api, store } = ctx
  const money = (amount) => formatMoney(amount, store.state.shop?.shop?.currency)
  const orderId = initial?.id ?? id

  let order = initial || null
  let pollTimer = null
  let countdownTimer = null
  let failures = 0
  let cancelling = false
  let expired = false
  let loadFailed = false

  const content = h("div")
  const offline = h("p", { class: "ma-hint text-center", role: "status", hidden: true }, "Нет связи. Пробуем обновить статус…")
  const el = h("div", {}, content, offline)

  // Parts updated without redrawing the screen
  let countdown = null
  let payButton = null
  let cancelButton = null

  const payment = () => (order?.status === "INVOICE_CREATED" ? order.payment : null)

  // === Render ===
  function render() {
    stopCountdown()
    countdown = payButton = cancelButton = null

    if (!order) {
      fill(content, loadFailed ? loadError() : h("div", { class: "ma-notice" }, h("div", { class: "ma-spinner", role: "status", "aria-label": "Загружаем заказ" })))
      return
    }

    const info = statusInfo(order)
    fill(content,
      h("header", { class: "ma-header" },
        h("h1", { class: "ma-title" }, `Заказ #${order.id}`),
        h("span", { class: `ma-status-pill ${toneClass(info.tone)}` }, info.short)),
      h("p", { class: "ma-subtitle" }, formatDateTime(order.created_at)),
      payment() ? paymentBlock(payment()) : statusBlock(info),
      itemsBlock(),
      order.can_cancel ? cancelBlock() : null)

    if (payment()) startCountdown()
  }

  function paymentBlock(pay) {
    countdown = h("p", { class: "ma-countdown", "aria-live": "off" })
    payButton = button({ class: "ma-btn mt-5", onclick: payNow }, h("span", { "aria-hidden": "true" }, "💳"), "Оплатить в O!Деньги")

    const qr = pay.qr_image_url
      ? h("section", { class: "ma-card mt-3 p-5 text-center", "aria-labelledby": "qr-title" },
        h("h2", { class: "font-semibold", id: "qr-title" }, "Оплата с другого телефона"),
        h("p", { class: "ma-subtitle mb-4 mt-1" }, "Отсканируйте QR-код в приложении O!Деньги"),
        h("div", { class: "ma-qr" }, h("img", {
          src: pay.qr_image_url,
          alt: `QR-код для оплаты заказа #${order.id}`,
          width: 212,
          height: 212,
          decoding: "async",
          referrerpolicy: "no-referrer",
          onerror: (event) => event.target.closest("section")?.remove()
        })))
      : null

    return h("div", {},
      h("section", { class: "ma-card mt-4 p-5", "aria-labelledby": "pay-title" },
        h("h2", { class: "text-center font-medium text-tg-hint", id: "pay-title" }, "К оплате"),
        h("p", { class: "ma-amount mt-1" }, money(order.total)),
        countdown,
        payButton,
        h("p", { class: "ma-hint text-center" }, "Откроется O!Деньги. После оплаты вернитесь сюда: статус обновится сам.")),
      qr)
  }

  function statusBlock(info) {
    const steps = info.step === undefined
      ? null
      : h("ol", { class: "ma-steps", "aria-label": "Этапы заказа" }, STEPS.map((label, i) => h("li", {
        class: `ma-step${i <= info.step ? " is-done" : ""}${i === info.step && i < STEPS.length - 1 ? " is-current" : ""}`,
        "aria-current": i === info.step ? "step" : null
      }, label)))

    return h("section", { class: "ma-card ma-status mt-4", role: "status" },
      h("div", { class: "ma-status-emoji", "aria-hidden": "true" }, info.emoji),
      h("h2", { class: "ma-status-title" }, info.title),
      info.text ? h("p", { class: "ma-status-text" }, info.text) : null,
      steps)
  }

  function itemsBlock() {
    return h("section", { "aria-labelledby": "order-items-title" },
      h("h2", { class: "ma-label", id: "order-items-title" }, "Состав заказа"),
      h("div", { class: "ma-card ma-list" },
        (order.items || []).map((item) => h("div", { class: "ma-row" },
          h("div", { class: "ma-row-main" },
            h("div", { class: "ma-row-title" }, item.name),
            h("div", { class: "ma-row-sub" }, `${item.qty} шт.`)),
          h("div", { class: "ma-row-end" }, money(item.line_total)))),
        h("div", { class: "ma-row ma-total" }, h("span", {}, "Итого"), h("span", {}, money(order.total)))),
      order.comment ? h("p", { class: "ma-hint" }, `Комментарий: ${order.comment}`) : null)
  }

  function cancelBlock() {
    cancelButton = button({ class: "ma-btn ma-btn-text ma-btn-danger mt-4", onclick: cancel, disabled: cancelling }, "Отменить заказ")
    return cancelButton
  }

  function loadError() {
    return h("div", { class: "ma-notice" },
      h("div", { class: "ma-notice-emoji", "aria-hidden": "true" }, "📡"),
      h("h2", { class: "ma-notice-title" }, "Не удалось загрузить заказ"),
      h("p", { class: "ma-notice-text" }, "Проверьте интернет и попробуйте ещё раз."),
      button({ class: "ma-btn", onclick: retry }, "Повторить"))
  }

  // === Countdown to payment.expires_at ===
  function startCountdown() {
    const expiresAt = new Date(payment()?.expires_at || "").getTime()
    if (Number.isNaN(expiresAt)) {
      countdown.hidden = true
      return
    }

    const tick = () => {
      const left = expiresAt - serverNow()
      const wasExpired = expired
      expired = left <= 0
      countdown.textContent = expired ? "Время на оплату истекло" : `Оплатите в течение ${formatCountdown(left)}`
      countdown.classList.toggle("is-urgent", left < 60_000)
      if (payButton) payButton.disabled = expired
      if (expired && !wasExpired) {
        stopCountdown()
        ctx.refresh(screen)
        poll(0) // the server expires the order shortly
      }
    }
    expired = false
    tick()
    if (!expired) countdownTimer = setInterval(tick, 1000)
  }

  function stopCountdown() {
    clearInterval(countdownTimer)
    countdownTimer = null
  }

  // === Polling ===
  async function load() {
    try {
      const next = await api.order(orderId)
      failures = 0
      loadFailed = false
      offline.hidden = true
      apply(next)
    } catch (error) {
      if (error.status === 401 || error.code === "shop_unavailable") return ctx.fail(error)
      if (error.status === 404) {
        ctx.toast("Заказ не найден")
        return ctx.back()
      }
      failures += 1
      if (!order) {
        loadFailed = true
        render()
      } else if (failures >= 2) {
        offline.hidden = false
      }
    }
    poll()
  }

  function poll(delay) {
    clearTimeout(pollTimer)
    pollTimer = null
    if (!screen.active || (order && !isOpen(order)) || (!order && loadFailed)) return

    const wait = delay ?? (failures ? Math.min(POLL_MS * 2 ** failures, MAX_BACKOFF_MS) : POLL_MS)
    // Paused while the app is hidden: resume() polls at once when it's back
    pollTimer = setTimeout(() => (document.hidden ? poll() : load()), wait)
  }

  function apply(next) {
    const previous = order
    order = next
    const changed = !previous || previous.status !== next.status || previous.refund_required !== next.refund_required ||
      previous.can_cancel !== next.can_cancel || JSON.stringify(previous.payment) !== JSON.stringify(next.payment)
    if (!changed) return

    store.upsertOrder(next)
    render()
    ctx.refresh(screen)
    if (previous && previous.status !== next.status) announce(next)
  }

  function announce(next) {
    if (next.refund_required) haptic.notify("warning")
    else if (next.status === "PAID") {
      haptic.notify("success")
      ctx.toast("Оплата получена! Заказ передан баристе")
    } else if (next.status === "READY") haptic.notify("success")
    else if (next.status === "EXPIRED" || next.status === "CANCELLED") haptic.notify("warning")
    window.scrollTo({ top: 0, behavior: "smooth" })
  }

  function retry() {
    loadFailed = false
    failures = 0
    render()
    load()
  }

  // === Actions ===
  function payNow() {
    const pay = payment()
    const url = pay?.app_url || pay?.paylink_url
    if (!url || expired) return

    haptic.impact("medium")
    openLink(url)
    poll(POLL_MS)
  }

  async function cancel() {
    if (cancelling || !order?.can_cancel) return

    const ok = await showConfirm(`Отменить заказ #${order.id}?`, { confirmText: "Отменить заказ", cancelText: "Не отменять", destructive: true })
    if (!ok) return

    cancelling = true
    if (cancelButton) cancelButton.disabled = true
    try {
      const result = await api.cancelOrder(order.id)
      if (result?.order) apply(result.order)
      if (result?.outcome === "cancelled") {
        haptic.notify("success")
        ctx.toast("Заказ отменён")
      } else {
        await showAlert(CANCEL_OUTCOMES[result?.outcome] || CANCEL_OUTCOMES.not_cancellable)
      }
    } catch (error) {
      ctx.fail(error)
    } finally {
      cancelling = false
      if (cancelButton) cancelButton.disabled = false
      poll()
    }
  }

  const screen = {
    el,
    active: false,

    main() {
      if (!order) return null
      if (payment() && !expired) return { text: `Оплатить · ${money(order.total)}`, onClick: payNow, shine: true }
      if (isOpen(order)) return { text: "Вернуться в меню", onClick: () => ctx.home() }
      return { text: "Сделать новый заказ", onClick: () => ctx.home() }
    },

    enter() {
      screen.active = true
      render()
      if (!order) load()
      else poll(fresh ? POLL_MS : 0)
      fresh = false
    },

    leave() {
      screen.active = false
      clearTimeout(pollTimer)
      stopCountdown()
    },

    // Back from the payment app / another chat
    resume() {
      if (screen.active && (!order || isOpen(order))) poll(0)
    },

    destroy() {
      screen.leave()
    }
  }

  if (!mainButton.supported) {
    // Without a MainButton the in-page buttons are the only actions
    screen.main = () => null
  }
  return screen
}
