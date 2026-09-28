// How an order status is shown to the customer (the API's status_text is the fallback)

// The status screen polls these
export const OPEN_STATUSES = [ "NEW", "INVOICE_CREATED", "PAID", "IN_PROGRESS" ]

export const STEPS = [ "Оплата", "Передан баристе", "Готовится", "Готов" ]

const STATUS = {
  NEW: { emoji: "⏳", title: "Создаём счёт на оплату", text: "Это займёт несколько секунд.", tone: "open", step: 0 },
  INVOICE_CREATED: {
    emoji: "💳", title: "Ожидает оплату", text: "Оплатите заказ в O!Деньги: статус обновится сам.", tone: "open", step: 0
  },
  PAID: { emoji: "✅", title: "Оплачен, передан баристе", text: "Мы напишем в чат, когда заказ будет готов.", tone: "good", step: 1 },
  IN_PROGRESS: { emoji: "☕", title: "Готовится", text: "Бариста уже готовит ваш заказ.", tone: "good", step: 2 },
  READY: {
    emoji: "🎉", title: "Готов — заберите на стойке", text: (order) => `Назовите баристе номер заказа #${order.id}.`, tone: "good", step: 3
  },
  CANCELLED: { emoji: "❌", title: "Отменён", text: "Этот заказ отменён.", tone: "muted" },
  EXPIRED: { emoji: "⌛", title: "Истёк", text: "Время на оплату вышло. Оформите заказ заново.", tone: "muted" },
  ERROR: {
    emoji: "⚠️", title: "Не удалось оформить заказ", text: "Если вы уже оплатили, бариста проверит платёж и свяжется с вами.", tone: "bad"
  }
}

// Paid after the invoice expired / the order was cancelled: not prepared, money goes back
const REFUND = {
  emoji: "💸",
  title: "Оплата пришла после истечения срока, деньги вернут",
  text: "Заказ не будет приготовлен. Если деньги не вернулись, обратитесь к баристе.",
  tone: "bad",
  short: "Возврат оплаты"
}

// { emoji, title, text, tone, step?, short }
export function statusInfo(order) {
  if (order.refund_required) return REFUND

  const info = STATUS[order.status]
  if (!info) return { emoji: "ℹ️", title: order.status_text || "Статус обновляется", text: "", tone: "muted", short: order.status_text || "" }

  const text = typeof info.text === "function" ? info.text(order) : info.text
  return { ...info, text, short: order.status_text || info.title }
}

export function isOpen(order) {
  return Boolean(order) && OPEN_STATUSES.includes(order.status) && !order.refund_required
}

export function toneClass(tone) {
  return { good: "is-good", bad: "is-bad", muted: "is-muted" }[tone] || ""
}
