// Full-screen message: opened outside Telegram, session expired, shop closed, load failed

import { h, button } from "mini_app/dom"
import { mainButton } from "mini_app/telegram"

// action: { text, onClick } (the MainButton, or a button on the page without one)
// link: { text, href } (a normal link, e.g. to the bot)
export function noticeScreen({ emoji, title, text, action, link }) {
  const el = h("div", { class: "ma-notice", role: "status" },
    h("div", { class: "ma-notice-emoji", "aria-hidden": "true" }, emoji),
    h("h1", { class: "ma-notice-title" }, title),
    text ? h("p", { class: "ma-notice-text" }, text) : null,
    link ? h("a", { class: "ma-btn", href: link.href, target: "_blank", rel: "noopener" }, link.text) : null,
    action && !mainButton.supported ? button({ class: "ma-btn", onclick: action.onClick }, action.text) : null)

  return {
    el,
    main: () => (action ? { text: action.text, onClick: action.onClick } : null)
  }
}
