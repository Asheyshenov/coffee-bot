# Telegram Mini App: API contract

The customer Mini App of a coffee shop's bot. The page `GET /app/:bot_id` is a shell (HTML + JS). All data comes from the JSON API under `/app/:bot_id/api`. The cart is the same `Draft` the chat bot uses: whatever the customer adds in the chat shows up in the app, and the other way round.

## Authentication

Every API request carries the header `X-Telegram-Init-Data: <Telegram.WebApp.initData>`.

The server checks this data (Telegram "Validating data received via the Mini App"):
- `secret_key = HMAC_SHA256(key: "WebAppData", data: bot_token)`
- `hash == hex(HMAC_SHA256(key: secret_key, data: data_check_string))`, compared in constant time
- `data_check_string` is every field except `hash`, sorted by key and joined as `key=value` with `\n`
- `auth_date` is no older than 24 h

Other rules:
- `bot_token` is the token of the bot in the URL (`Bot.find_by(id: :bot_id, active: true)`). The bot determines the tenant.
- The customer is `Customer` of that tenant for `initData.user.id`, with profile fields updated.
- `401 {"error":"unauthorized"}` for a missing, invalid or expired initData.
- `404 {"error":"not_found"}` for an unknown or inactive bot.
- `503 {"error":"shop_unavailable"}` when the tenant is not serving.

## Money

Amounts are integers in tyiyn (`15000` = 150 KGS). The frontend formats them: `150 сом`, or `150.50 сом` when there are tyiyn.

## Endpoints

### `GET /api/shop`
```json
{
  "shop": { "name": "Coffee Bot", "currency": "KGS", "order_expire_minutes": 15 },
  "categories": [ { "name": "☕ Кофе", "key": "кофе" } ],
  "items": [
    { "id": 1, "category": "☕ Кофе", "name": "Латте", "description": null,
      "price": 15000, "default_size": "medium",
      "sizes": [ { "size": "small", "label": "S", "price": 13000 },
                 { "size": "medium", "label": "M", "price": 15000 },
                 { "size": "large", "label": "L", "price": 19000 } ] },
    { "id": 2, "category": "🍰 Десерты", "name": "Круассан", "description": null,
      "price": 12000, "default_size": null, "sizes": [] }
  ]
}
```
- Only available items are returned.
- Categories come in menu order and only include categories that have items. `key` is `MenuItem.category_key`.

### Cart: `GET /api/cart`, and every cart mutation
```json
{
  "items": [ { "index": 0, "menu_item_id": 1, "name": "Латте", "display_name": "Латте (M)",
               "size": "medium", "qty": 2, "unit_price": 15000, "line_total": 30000 } ],
  "total": 30000, "count": 2, "comment": null, "max_qty_per_line": 20
}
```
- `POST /api/cart/items {"menu_item_id":1, "size":"medium"|null, "qty":1}` adds a line or merges it with an existing one. The line is capped at 20.
- `422 {"error":"invalid_qty"}` for qty < 1.
- `422 {"error":"item_unavailable"}` for an unknown or unavailable item, or a size the item doesn't have.
- `PATCH /api/cart/items/:index {"qty":3}` sets the quantity (1..20). `qty` 0 removes the line.
- `DELETE /api/cart/items/:index` removes a line. `DELETE /api/cart` empties the cart.
- `404 {"error":"not_found"}` for an index that doesn't exist.

### `POST /api/orders {"comment":"без сахара"}`
The comment is optional and truncated to 200 characters. Order of operations:
1. The cart is checked against the menu (`Draft#sync_with_menu!`). If anything changed, the response is `409 {"error":"cart_changed","removed":["Круассан"],"repriced":["Латте (M)"],"cart":{...}}`. The client shows the change and asks the customer to confirm again.
2. For an empty cart: `422 {"error":"empty_cart"}`.
3. `OrderService.create_from_draft` and `OrderService.create_invoice` run. After that the cart is cleared.
4. On an invoice failure: `502 {"error":"invoice_failed"}` with no provider text. The cart is kept.
5. On success: `201` with the order (below). The chat bot doesn't send a second QR message for Mini App orders.

### `GET /api/orders` (the customer's latest 10) and `GET /api/orders/:id`
```json
{
  "id": 42, "status": "INVOICE_CREATED", "status_text": "Ожидает оплату",
  "created_at": "2026-09-28T12:00:00+06:00",
  "items": [ { "name": "Латте (M)", "qty": 2, "line_total": 30000 } ],
  "total": 30000, "comment": null,
  "payment": { "app_url": "https://o.kg/l/a?t=wl_unpbill&id=…", "paylink_url": "https://…",
               "qr_image_url": "https://…/qr.php?…", "expires_at": "2026-09-28T12:15:00+06:00" },
  "refund_required": false,
  "can_cancel": true
}
```
- `payment` is present only while the order is `INVOICE_CREATED`.
- `can_cancel` is true for NEW and INVOICE_CREATED.
- An order of another customer gets `404`.
- `GET /api/orders` returns `{"orders":[…]}`.

### `POST /api/orders/:id/cancel`
Runs `OrderService.cancel_by_client`. Returns `{"outcome":"cancelled"|"cancelled_locally"|"paid_now"|"already_paid"|"in_progress"|"payment_problem"|"not_cancellable","order":{...}}`, and triggers the same winner-only notifications as `/cancel` in the chat.

### Implementation notes
Details the implementation settles (`app/controllers/mini_app/api`):
- Checks run in this order: 404 bot, 503 shop, 401 initData. initData whose `user` has no integer `id` is 401.
- Extra error codes: `400 bad_request` for a malformed JSON body, `422 invalid_comment` when `comment` is not a string, `500 internal_error`.
- Cart mutations answer `200` with the cart.
- `POST /api/cart/items`:
  - `qty` defaults to 1 when the key is absent. A present but non-integer `qty` (`1.5`, `"x"`, `null`) is `invalid_qty`.
  - `size: null` on an item with sizes means its `default_size`, as `GET /api/shop` reports it. A size on an item without sizes is `item_unavailable`.
- `PATCH /api/cart/items/:index` accepts `qty` 0..20 only. Anything else is `422 invalid_qty`; the value is not capped.
- `GET /api/shop`: `price` of an item with sizes is the price of its `default_size`.
- `POST /api/orders`: without a `comment` key, the cart keeps its comment (e.g. one typed in the chat). `null` or blank clears it.
- The `payment` key is always there: `null` unless the order is `INVOICE_CREATED`.

## Page `GET /app/:bot_id`
- 404 for an unknown or inactive bot. The page doesn't need initData: the hash fragment `#tgWebAppData` is never sent to the server.
- Telegram Desktop and Web embed Mini Apps in an iframe, so these responses drop `X-Frame-Options` and send `Content-Security-Policy: frame-ancestors https://web.telegram.org https://*.telegram.org`.
- Loads `https://telegram.org/js/telegram-web-app.js` and the app module.
- UI:
  - Telegram theme colours (`--tg-theme-*`); MainButton for the main action; BackButton for navigation.
  - Screens: menu → item → cart → checkout → payment → order status, with polling every 3 s while the order is open.
  - "Мои заказы".
  - "Оплатить в O!Деньги" opens `payment.app_url` (fallback `paylink_url`) with `Telegram.WebApp.openLink`. A QR is shown for paying from another phone.

## Bot integration
- `Bot#mini_app_url` is `"#{public_base_url}/app/#{id}"`.
- `BotRegistration` sets the chat menu button: `setChatMenuButton(menu_button: {type: "web_app", text: "☕ Меню", web_app: {url:}})`.
- `/start` adds an inline `web_app` button "☕ Открыть меню". The chat ordering flow stays as a fallback.
- `tenants:refresh_bot[slug]` re-runs the webhook, commands and menu-button setup for an already connected bot.
