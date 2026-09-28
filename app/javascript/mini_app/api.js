// Client of the Mini App JSON API (plans/mini-app-api.md). Every request is signed with
// Telegram's initData in the X-Telegram-Init-Data header.

const TIMEOUT_MS = 20_000
// Checkout waits for the payment provider to issue the invoice
const CHECKOUT_TIMEOUT_MS = 90_000

// Server time minus phone time, from the Date header (the payment countdown must not
// trust a phone clock that runs fast or slow). Ignored within 3 s: Date has 1 s precision.
let clockOffset = 0
const CLOCK_TOLERANCE_MS = 3000

export function serverNow() {
  return Date.now() + clockOffset
}

function syncClock(response) {
  const serverTime = Date.parse(response.headers.get("Date") || "")
  if (Number.isNaN(serverTime)) return

  const offset = serverTime - Date.now()
  clockOffset = Math.abs(offset) > CLOCK_TOLERANCE_MS ? offset : 0
}

export class ApiError extends Error {
  // status 0: no response (offline, timeout)
  constructor(status, code, data = null) {
    super(code || `HTTP ${status}`)
    this.name = "ApiError"
    this.status = status
    this.code = code
    this.data = data
  }

  get offline() {
    return this.status === 0
  }
}

export function createApi(base, initData) {
  async function request(method, path, { body, timeout = TIMEOUT_MS } = {}) {
    const controller = typeof AbortController === "function" ? new AbortController() : null
    const timer = controller && setTimeout(() => controller.abort(), timeout)
    const headers = { Accept: "application/json", "X-Telegram-Init-Data": initData }
    if (body !== undefined) headers["Content-Type"] = "application/json"

    let response
    try {
      response = await fetch(`${base}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        credentials: "same-origin",
        cache: "no-store",
        signal: controller?.signal
      })
    } catch {
      throw new ApiError(0, controller?.signal.aborted ? "timeout" : "network_error")
    } finally {
      clearTimeout(timer)
    }
    syncClock(response)

    let data = null
    try {
      const text = await response.text()
      data = text ? JSON.parse(text) : null
    } catch {
      data = null
    }
    if (!response.ok) throw new ApiError(response.status, data?.error || null, data)

    return data
  }

  return {
    shop: () => request("GET", "/shop"),

    cart: () => request("GET", "/cart"),
    addToCart: (menuItemId, size, qty) => request("POST", "/cart/items", { body: { menu_item_id: menuItemId, size: size || null, qty } }),
    setQty: (index, qty) => request("PATCH", `/cart/items/${index}`, { body: { qty } }),
    removeLine: (index) => request("DELETE", `/cart/items/${index}`),
    clearCart: () => request("DELETE", "/cart"),

    orders: () => request("GET", "/orders"),
    order: (id) => request("GET", `/orders/${encodeURIComponent(id)}`),
    // Blank comment: no comment (the field shows the cart's comment, so it is always sent)
    createOrder: (comment) => request("POST", "/orders", { body: { comment }, timeout: CHECKOUT_TIMEOUT_MS }),
    cancelOrder: (id) => request("POST", `/orders/${encodeURIComponent(id)}/cancel`)
  }
}

// Russian text for an error; the raw error never reaches the customer
export function errorMessage(error) {
  if (!(error instanceof ApiError)) return "Что-то пошло не так. Попробуйте ещё раз."
  if (error.code === "timeout") return "Сервер долго не отвечает. Проверьте интернет и попробуйте ещё раз."
  if (error.offline) return "Нет соединения. Проверьте интернет и попробуйте ещё раз."

  switch (error.code) {
    case "invalid_qty": return "Можно заказать от 1 до 20 штук одной позиции."
    case "item_unavailable": return "Эта позиция сейчас недоступна."
    case "empty_cart": return "Корзина пуста: добавьте что-нибудь из меню."
    case "invoice_failed": return "Не удалось создать счёт на оплату. Попробуйте ещё раз через минуту."
    case "shop_unavailable": return "Кофейня сейчас не принимает заказы."
    case "invalid_comment": return "Не получилось сохранить комментарий. Измените его и попробуйте ещё раз."
    case "not_found": return "Не нашли это. Обновите экран и попробуйте ещё раз."
    case "unauthorized": return "Сессия устарела. Откройте меню заново через бота."
  }
  if (error.status === 429) return "Слишком много запросов. Подождите немного."
  if (error.status >= 500) return "Сервер временно недоступен. Попробуйте ещё раз через минуту."
  return "Что-то пошло не так. Попробуйте ещё раз."
}
