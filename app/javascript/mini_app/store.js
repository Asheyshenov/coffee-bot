// App state: the menu, the cart (the same Draft the chat bot uses) and the latest orders.
// Screens subscribe and redraw what changed ("shop", "cart" or "orders").
//
// Cart changes go to the server one at a time, in order. Quantity taps update the screen
// at once and are sent after a short pause (one PATCH for several quick taps).

const QTY_DEBOUNCE_MS = 350
export const MAX_QTY_PER_LINE = 20

export function emptyCart() {
  return { items: [], total: 0, count: 0, comment: null, max_qty_per_line: MAX_QTY_PER_LINE }
}

function normalizeCart(cart) {
  const base = emptyCart()
  if (!cart || typeof cart !== "object") return base
  return { ...base, ...cart, items: Array.isArray(cart.items) ? cart.items.map((line) => ({ ...line })) : [] }
}

function recount(cart) {
  cart.total = cart.items.reduce((sum, line) => sum + (line.line_total || 0), 0)
  cart.count = cart.items.reduce((sum, line) => sum + (line.qty || 0), 0)
  return cart
}

export function createStore(api, { onError }) {
  const listeners = new Set()
  // cartVersion: bumped on every cart change (a slow reload must not undo a newer one)
  const state = { shop: null, cart: emptyCart(), cartVersion: 0, orders: null }
  const emit = (what) => listeners.forEach((listener) => listener(what))

  const store = {
    state,

    subscribe(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },

    setShop(shop) {
      state.shop = shop
      emit("shop")
    },

    setCart(cart) {
      state.cart = normalizeCart(cart)
      state.cartVersion += 1
      emit("cart")
    },

    setOrders(orders) {
      state.orders = Array.isArray(orders) ? orders : []
      emit("orders")
    },

    // A fresh copy of one order (status screen, checkout, cancel)
    upsertOrder(order) {
      if (!order?.id) return
      const orders = (state.orders || []).filter((o) => o.id !== order.id)
      orders.push(order)
      orders.sort((a, b) => b.id - a.id)
      state.orders = orders
      emit("orders")
    },

    menuItem(id) {
      return state.shop?.items?.find((item) => item.id === id) || null
    }
  }

  store.cart = createCartOps(api, store, onError)
  return store
}

function createCartOps(api, store, onError) {
  let chain = Promise.resolve()
  let queued = 0
  const pendingQty = new Map() // line index -> { timer, qty }

  function local() {
    return store.state.cart
  }

  // Runs a request after the previous ones; the screen shows the server's cart once
  // nothing else is waiting (earlier answers would undo later optimistic changes)
  function enqueue(request) {
    queued += 1
    const result = chain.then(request).then(
      (cart) => {
        queued -= 1
        if (queued === 0 && pendingQty.size === 0) store.setCart(cart)
        return cart
      },
      async (error) => {
        queued -= 1
        try {
          store.setCart(await api.cart())
        } catch {
          // keep what is shown; the next change or reload fixes it
        }
        throw error
      }
    )
    chain = result.catch(() => undefined)
    return result
  }

  function sendQty(index, qty) {
    enqueue(() => api.setQty(index, qty)).catch(onError)
  }

  function flushQty() {
    for (const [ index, { timer, qty } ] of pendingQty) {
      clearTimeout(timer)
      pendingQty.delete(index)
      sendQty(index, qty)
    }
  }

  return {
    get idle() {
      return queued === 0 && pendingQty.size === 0
    },

    // Not optimistic: the server merges the line with an existing one and caps it at 20
    add(menuItemId, size, qty) {
      flushQty()
      return enqueue(() => api.addToCart(menuItemId, size, qty))
    },

    setQty(index, qty) {
      const cart = local()
      const line = cart.items.find((l) => l.index === index)
      if (!line) return

      const max = cart.max_qty_per_line || MAX_QTY_PER_LINE
      const value = Math.min(Math.max(1, qty), max)
      if (value === line.qty) return

      line.qty = value
      line.line_total = (line.unit_price || 0) * value
      store.setCart(recount(cart))

      clearTimeout(pendingQty.get(index)?.timer)
      const timer = setTimeout(() => {
        pendingQty.delete(index)
        sendQty(index, value)
      }, QTY_DEBOUNCE_MS)
      pendingQty.set(index, { timer, qty: value })
    },

    // The line disappears at once. Later lines move up one index, as they do on the server.
    remove(index) {
      flushQty()
      const cart = local()
      cart.items = cart.items
        .filter((line) => line.index !== index)
        .map((line) => (line.index > index ? { ...line, index: line.index - 1 } : line))
      store.setCart(recount(cart))
      return enqueue(() => api.removeLine(index)).catch(onError)
    },

    clear() {
      flushQty()
      store.setCart({ ...local(), items: [], total: 0, count: 0 })
      return enqueue(() => api.clearCart()).catch(onError)
    },

    // Waits until every change has reached the server (before checkout)
    async settle() {
      flushQty()
      await chain
    }
  }
}
