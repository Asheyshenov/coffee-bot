# frozen_string_literal: true

# Draft Model
# Stores the current order wizard state for each user
# State is persisted in database to survive bot restarts

require_relative '../../config/boot'
require 'json'

class Draft < Sequel::Model
  # Default state structure
  DEFAULT_STATE = {
    'step' => 'select_category',
    'category' => nil,
    'items' => [],
    'comment' => nil
  }.freeze

  # Crafted callbacks can carry any quantity: one cart line holds 1..MAX_QTY_PER_LINE
  MAX_QTY_PER_LINE = 20

  # Same limit as orders.comment
  COMMENT_MAX_LENGTH = 200

  # Valid wizard steps
  STEPS = %w[
    select_category
    select_item
    select_qty
    cart
    add_comment
    confirm
  ].freeze

  # Scopes
  dataset_module do
    def for_user(telegram_user_id)
      where(telegram_user_id: telegram_user_id).first
    end

    def stale(minutes: 60)
      where { updated_at < Time.now.utc - (minutes * 60) }
    end
  end

  # Class methods

  # Get or create draft for user
  def self.get_or_create(telegram_user_id)
    find_or_create(telegram_user_id: telegram_user_id) do |draft|
      draft.telegram_user_id = telegram_user_id
      draft.state_json = DEFAULT_STATE.to_json
    end
  end

  # Get state for user (returns hash)
  def self.get_state(telegram_user_id)
    draft = for_user(telegram_user_id)
    draft ? draft.state : DEFAULT_STATE.dup
  end

  # Update state for user
  def self.update_state(telegram_user_id, updates)
    draft = get_or_create(telegram_user_id)
    draft.update_state(updates)
    draft.state
  end

  # Clear draft for user
  def self.clear(telegram_user_id)
    draft = for_user(telegram_user_id)
    draft&.destroy
  end

  # Instance methods

  # Parse state JSON
  def state
    JSON.parse(state_json)
  rescue JSON::ParserError
    DEFAULT_STATE.dup
  end

  # Update state with hash (merges with existing)
  def update_state(updates)
    current = state
    new_state = current.merge(updates)
    update(state_json: new_state.to_json)
    new_state
  end

  # Set specific step
  def set_step(step)
    update_state('step' => step)
  end

  # Get current step
  def current_step
    state['step']
  end

  # Get items in cart
  def items
    state['items'] || []
  end

  # Add item to cart (without size - for backward compatibility)
  def add_item(menu_item, qty)
    add_item_with_size(menu_item, nil, qty)
  end

  # Add item to cart with size support
  # @param menu_item [MenuItem] The menu item
  # @param size [String, nil] Size key (small, medium, large) or nil
  # @param qty [Integer] Quantity (non-positive is rejected, the line is capped at MAX_QTY_PER_LINE)
  # @return [Boolean] False if nothing was added
  def add_item_with_size(menu_item, size, qty)
    qty = qty.to_i
    return false unless qty.positive?

    current_items = items
    unit_price = menu_item.price_for_size(size)
    display_name = menu_item.display_name_for_size(size)
    
    # Check if item with same size already exists in cart
    existing = current_items.find do |i|
      i['menu_item_id'] == menu_item.id && i['size'] == size
    end
    
    if existing
      existing['qty'] = [existing['qty'] + qty, MAX_QTY_PER_LINE].min
      existing['line_total'] = existing['qty'] * existing['unit_price']
    else
      qty = [qty, MAX_QTY_PER_LINE].min
      current_items << {
        'menu_item_id' => menu_item.id,
        'name' => menu_item.name,
        'size' => size,
        'display_name' => display_name,
        'unit_price' => unit_price,
        'qty' => qty,
        'line_total' => unit_price * qty
      }
    end
    
    update_state('items' => current_items)
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
      name = item['display_name'] || item['name']
      menu_item = MenuItem[item['menu_item_id']]
      unless menu_item&.is_available
        removed << name
        next
      end

      unit_price = menu_item.price_for_size(item['size'])
      repriced << name if unit_price != item['unit_price']
      item.merge('unit_price' => unit_price, 'line_total' => unit_price * item['qty'].to_i)
    end

    update_state('items' => current_items) if removed.any? || repriced.any?
    { removed: removed, repriced: repriced }
  end

  # Remove item from cart by index
  def remove_item(index)
    current_items = items
    current_items.delete_at(index) if index >= 0 && index < current_items.length
    update_state('items' => current_items)
  end

  # Update item quantity
  def update_item_qty(index, qty)
    current_items = items
    if index >= 0 && index < current_items.length && qty.to_i.positive?
      qty = [qty.to_i, MAX_QTY_PER_LINE].min
      current_items[index]['qty'] = qty
      current_items[index]['line_total'] = qty * current_items[index]['unit_price']
      update_state('items' => current_items)
    end
  end

  # Calculate total amount in tyiyn
  def total_amount
    items.sum { |item| item['line_total'] || 0 }
  end

  # Format total for display
  def formatted_total
    kgs = total_amount.to_i / 100
    format('%d KGS', kgs)
  end

  # Get comment
  def comment
    state['comment']
  end

  # Set comment (truncated to the orders.comment column size; blank -> no comment)
  def set_comment(text)
    text = text.to_s.strip
    update_state('comment' => text.empty? ? nil : text[0, COMMENT_MAX_LENGTH])
  end

  # Clear cart
  def clear_cart
    update_state(DEFAULT_STATE.dup)
  end

  # Check if cart is empty
  def empty?
    items.empty?
  end

  # Number of items in cart
  def item_count
    items.sum { |i| i['qty'] || 0 }
  end

  # Format cart for display
  def format_cart
    return 'Корзина пуста' if empty?

    lines = items.each_with_index.map do |item, idx|
      price_kgs = item['unit_price'].to_i / 100
      total_kgs = item['line_total'].to_i / 100
      # Use display_name which includes size if present
      display = item['display_name'] || item['name']
      "#{idx + 1}. #{display} x#{item['qty']} @ #{price_kgs} = #{total_kgs} KGS"
    end
    
    lines << ''
    lines << "Итого: #{formatted_total}"
    lines.join("\n")
  end
end
