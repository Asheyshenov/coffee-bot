// Tiny DOM builder. Text always goes in as text nodes: menu and order data are never
// parsed as HTML.
//
//   h("button", { type: "button", class: "ma-btn", onclick: pay }, "Оплатить")

export function h(tag, props, ...children) {
  const el = document.createElement(tag)
  for (const [ key, value ] of Object.entries(props || {})) {
    if (value === null || value === undefined || value === false) continue

    if (key === "class") el.className = value
    else if (key === "text") el.textContent = value
    else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2).toLowerCase(), value)
    else if (key === "value") el.value = value
    else if (value === true) el.setAttribute(key, "")
    else el.setAttribute(key, String(value))
  }
  append(el, children)
  return el
}

export function append(el, children) {
  for (const child of [ children ].flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue
    el.append(child instanceof Node ? child : String(child))
  }
  return el
}

// Replace the content of an element
export function fill(el, ...children) {
  el.replaceChildren()
  return append(el, children)
}

export function button(props, ...children) {
  return h("button", { type: "button", ...props }, ...children)
}
