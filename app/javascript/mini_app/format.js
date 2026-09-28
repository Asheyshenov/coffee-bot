// Formatting helpers. Money comes from the API in tyiyn (15000 = 150 KGS).

const NBSP = "\u00a0"

// 15000 -> "150 сом", 15050 -> "150.50 сом", 125000 -> "1 250 сом"
export function formatMoney(tyiyn, currency = "KGS") {
  const value = Math.round(Number(tyiyn) || 0)
  const abs = Math.abs(value)
  const whole = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, NBSP)
  const fraction = abs % 100
  const amount = fraction ? `${whole}.${String(fraction).padStart(2, "0")}` : whole
  return `${value < 0 ? "−" : ""}${amount}${NBSP}${currencyName(currency)}`
}

export function currencyName(currency) {
  return !currency || currency === "KGS" ? "сом" : currency
}

// plural(3, ["позиция", "позиции", "позиций"]) -> "позиции"
export function plural(count, [one, few, many]) {
  const mod10 = count % 10
  const mod100 = count % 100
  if (mod10 === 1 && mod100 !== 11) return one
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few
  return many
}

// 873000 ms -> "14:33"
export function formatCountdown(ms) {
  const total = Math.max(0, Math.ceil(ms / 1000))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const pad = (n) => String(n).padStart(2, "0")
  return hours ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${minutes}:${pad(seconds)}`
}

const timeFormat = new Intl.DateTimeFormat("ru-RU", { hour: "2-digit", minute: "2-digit" })
const dayFormat = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long" })

// "сегодня, 12:05", "вчера, 09:40", "27 сентября, 18:10"
export function formatDateTime(iso) {
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ""

  const today = new Date()
  const yesterday = new Date(today)
  yesterday.setDate(today.getDate() - 1)
  const day = sameDay(date, today) ? "сегодня" : sameDay(date, yesterday) ? "вчера" : dayFormat.format(date)
  return `${day}, ${timeFormat.format(date)}`
}

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

// Emoji of a category: the one in its name ("☕ Кофе"), else a guess from the words
const CATEGORY_EMOJI = [
  [ /коф|эспрессо|капуч|латте/, "☕" ],
  [ /ча[йия]/, "🍵" ],
  [ /десерт|торт|пирож|сладк/, "🍰" ],
  [ /выпеч|круасс|булоч/, "🥐" ],
  [ /завтрак/, "🍳" ],
  [ /сэндвич|сендвич|бутерброд|еда/, "🥪" ],
  [ /смузи|коктейл|шейк/, "🥤" ],
  [ /лимонад|сок|напит|холод/, "🧃" ],
  [ /добавк|сироп|топпинг/, "🍯" ]
]
const EMOJI_PATTERN = /\p{Extended_Pictographic}(?:\uFE0F|\u200D\p{Extended_Pictographic})*/u

export function categoryEmoji(name) {
  const text = String(name || "")
  const own = text.match(EMOJI_PATTERN)
  if (own) return own[0]

  const key = text.toLowerCase()
  return CATEGORY_EMOJI.find(([ pattern ]) => pattern.test(key))?.[1] || "🍽️"
}

export function truncate(text, max) {
  const value = String(text || "")
  return value.length > max ? `${value.slice(0, max - 1)}…` : value
}
