# frozen_string_literal: true

# Order wizard / cart state of a customer, persisted so it survives restarts.
# Cart lines are hashes: menu_item_id, name, size, display_name, unit_price, qty, line_total.
class Draft < ApplicationRecord
  DEFAULT_STATE = { "step" => "select_category", "category" => nil, "items" => [], "comment" => nil }.freeze

  # Crafted callbacks can carry any quantity: one cart line holds 1..MAX_QTY_PER_LINE
  MAX_QTY_PER_LINE = 20

  # Same limit as orders.comment
  COMMENT_MAX_LENGTH = 200

  STEPS = %w[select_category select_item select_qty cart add_comment confirm].freeze

  acts_as_tenant :tenant

  # One cart per customer and shop: enforced by the unique index (see Customer)
  validates :telegram_user_id, presence: true

  scope :stale, ->(minutes: 60) { where(updated_at: ...minutes.minutes.ago) }

  def self.for_user(telegram_user_id) = find_by(telegram_user_id: telegram_user_id)

  # Look up first: create_or_find_by! alone would hit the unique index on every call
  def self.get_or_create(telegram_user_id)
    for_user(telegram_user_id) ||
      create_or_find_by!(telegram_user_id: telegram_user_id) { |draft| draft.state = DEFAULT_STATE.deep_dup }
  end

  def self.get_state(telegram_user_id)
    for_user(telegram_user_id)&.state || DEFAULT_STATE.deep_dup
  end

  def self.update_state(telegram_user_id, updates)
    get_or_create(telegram_user_id).update_state(updates)
  end

  def self.clear(telegram_user_id)
    for_user(telegram_user_id)&.destroy
  end

  def state
    value = super
    value.is_a?(Hash) ? value : DEFAULT_STATE.deep_dup
  end

  # Merge updates into the state and save
  def update_state(updates)
    new_state = state.merge(updates.stringify_keys)
    update!(state: new_state)
    new_state
  end

  def set_step(step) = update_state("step" => step)
  def current_step = state["step"]
  def items = state["items"] || []
  def comment = state["comment"]

  # Set comment (truncated to the orders.comment column size; blank -> no comment)
  def set_comment(text)
    text = text.to_s.strip
    update_state("comment" => text.empty? ? nil : text[0, COMMENT_MAX_LENGTH])
  end

  def add_item(menu_item, qty) = add_item_with_size(menu_item, nil, qty)

  # @param qty [Integer] non-positive is rejected, the line is capped at MAX_QTY_PER_LINE
  # @return [Boolean] false if nothing was added
  def add_item_with_size(menu_item, size, qty)
    qty = qty.to_i
    return false unless qty.positive?

    current_items = items
    unit_price = menu_item.price_for_size(size)
    existing = current_items.find { |i| i["menu_item_id"] == menu_item.id && i["size"] == size }

    if existing
      existing["qty"] = [existing["qty"] + qty, MAX_QTY_PER_LINE].min
      existing["line_total"] = existing["qty"] * existing["unit_price"]
    else
      qty = [qty, MAX_QTY_PER_LINE].min
      current_items << {
        "menu_item_id" => menu_item.id,
        "name" => menu_item.name,
        "size" => size,
        "display_name" => menu_item.display_name_for_size(size),
        "unit_price" => unit_price,
        "qty" => qty,
        "line_total" => unit_price * qty
      }
    end

    update_state("items" => current_items)
    true
  end

  # Re-read prices and availability from the menu: prices may change and items may
  # be switched off while the cart is open. Unavailable lines are removed.
  #
  # @return [Hash] :removed and :repriced - display names of the affected lines
  def sync_with_menu!
    removed = []
    repriced = []

    current_items = items.filter_map do |item|
      name = item["display_name"] || item["name"]
      menu_item = MenuItem.find_by(id: item["menu_item_id"])
      unless menu_item&.available?
        removed << name
        next
      end

      unit_price = menu_item.price_for_size(item["size"])
      repriced << name if unit_price != item["unit_price"]
      item.merge("unit_price" => unit_price, "line_total" => unit_price * item["qty"].to_i)
    end

    update_state("items" => current_items) if removed.any? || repriced.any?
    { removed: removed, repriced: repriced }
  end

  def remove_item(index)
    current_items = items
    current_items.delete_at(index) if index >= 0 && index < current_items.length
    update_state("items" => current_items)
  end

  def update_item_qty(index, qty)
    current_items = items
    return unless index >= 0 && index < current_items.length && qty.to_i.positive?

    qty = [qty.to_i, MAX_QTY_PER_LINE].min
    current_items[index]["qty"] = qty
    current_items[index]["line_total"] = qty * current_items[index]["unit_price"]
    update_state("items" => current_items)
  end

  def total_amount = items.sum { |item| item["line_total"] || 0 }
  def formatted_total = format("%d KGS", total_amount.to_i / 100)
  def clear_cart = update_state(DEFAULT_STATE.deep_dup)
  def empty? = items.empty?
  def item_count = items.sum { |i| i["qty"] || 0 }

  def format_cart
    return "Корзина пуста" if empty?

    lines = items.each_with_index.map do |item, idx|
      display = item["display_name"] || item["name"]
      "#{idx + 1}. #{display} x#{item['qty']} @ #{item['unit_price'].to_i / 100} = #{item['line_total'].to_i / 100} KGS"
    end
    lines << ""
    lines << "Итого: #{formatted_total}"
    lines.join("\n")
  end
end
