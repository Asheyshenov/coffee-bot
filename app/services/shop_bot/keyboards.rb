# frozen_string_literal: true

module ShopBot
  # Keyboard layouts of the coffee shop bot
  module Keyboards
    module_function

    def button(text, callback_data) = Telegram::Bot::Types::InlineKeyboardButton.new(text: text, callback_data: callback_data)
    def inline(rows) = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: rows)

    # Persistent reply keyboard under the input field
    def reply_keyboard
      Telegram::Bot::Types::ReplyKeyboardMarkup.new(
        keyboard: [
          [ { text: Router::PREORDER_BUTTON } ],
          [ { text: Router::MY_ORDERS_BUTTON }, { text: Router::HELP_BUTTON } ]
        ],
        resize_keyboard: true,
        one_time_keyboard: false
      )
    end

    def main_menu
      inline([
        [ button("☕ Кофе", "menu_coffee"), button("🍰 Десерты", "menu_desserts") ],
        [ button("🍵 Чай", "menu_tea"), button("➕ Добавки", "menu_addons") ],
        [ button("🔥 Популярное", "menu_popular") ],
        [ button("🛒 Корзина", "menu_cart"), button("📦 Мои заказы", "menu_orders") ]
      ])
    end

    # Category list of the /order wizard
    def categories_keyboard(categories)
      inline(categories.map { |category| [ button(category, "category_#{category}") ] })
    end

    # "Латте — от 130 KGS" for items with sizes, the price otherwise
    def item_price_text(item)
      item.has_sizes? ? "от #{item.formatted_price_for_size('small')}" : item.formatted_price
    end

    def item_buttons(items)
      items.map { |item| [ button("#{item.name} — #{item_price_text(item)}", "item_#{item.id}") ] }
    end

    # Items of a category in the /order wizard (back to the category list)
    def wizard_items_keyboard(items)
      inline(item_buttons(items) + [ [ button("⬅️ Назад", "cart_back") ] ])
    end

    # Items of a category in the main menu
    def category_keyboard(_category, items, back_button: true)
      navigation = [ [ button("⬅ Назад", "menu_back") ] ]
      navigation << [ button("🛒 Корзина", "menu_cart") ] if back_button
      inline(item_buttons(items) + navigation)
    end

    # Item detail (items without sizes)
    def item_keyboard(item)
      inline([
        [ button("➕ Добавить в корзину", "add_item_#{item.id}") ],
        [ button("➕ Добавки", "addons_#{item.id}") ],
        [ button("🔙 Назад", "menu_back") ]
      ])
    end

    # Size selector of a drink, all sizes in one row
    def size_keyboard(item)
      sizes = item.size_options.map { |opt| button("#{opt[:label]} #{opt[:formatted_price]}", "size_#{item.id}_#{opt[:size]}") }
      inline([ sizes, [ button("🔙 Назад", "menu_back") ] ])
    end

    # Quantity 1..5 in one row, after the size selection or for items without sizes
    def quantity_keyboard(item_id, size = nil)
      buttons = (1..5).map { |qty| button(qty.to_s, size ? "qty_#{item_id}_#{size}_#{qty}" : "qty_#{item_id}_#{qty}") }
      inline([ buttons, [ button("🔙 Назад", size ? "size_#{item_id}" : "item_#{item_id}") ] ])
    end

    # Quantity 1..5 one per row (/order wizard, items without sizes)
    def wizard_quantity_keyboard(item_id)
      inline((1..5).map { |qty| [ button(qty.to_s, "qty_#{item_id}_#{qty}") ] })
    end

    def cart_keyboard
      inline([
        [ button("➕ Добавить еще", "cart_add"), button("🗑 Очистить", "cart_clear") ],
        [ button("💳 Оплатить", "cart_checkout") ]
      ])
    end

    # Cart of the /order wizard
    def wizard_cart_keyboard
      inline([
        [ button("➕ Добавить", "cart_add"), button("🗑 Очистить", "cart_clear") ],
        [ button("✅ Оформить", "cart_checkout") ]
      ])
    end

    # One remove button per cart line
    def cart_edit_keyboard(draft)
      rows = draft.items.each_with_index.map do |item, index|
        [ button("❌ #{item['display_name'] || item['name']} x#{item['qty']}", "cart_remove_#{index}") ]
      end
      inline(rows + [ [ button("⬅ Назад", "menu_cart") ] ])
    end

    def skip_comment_keyboard = inline([ [ button("⏭ Пропустить", "skip_comment") ] ])

    def confirm_keyboard = inline([ [ button("✅ Да", "confirm_yes"), button("❌ Нет", "confirm_no") ] ])

    def navigation_keyboard(back_action: "menu_back", cart_action: nil)
      rows = [ [ button("⬅ Назад", back_action) ] ]
      rows << [ button("🏠 Главное меню", "menu_main") ] if back_action != "menu_back"
      rows << [ button("🛒 Корзина", "menu_cart") ] if cart_action
      inline(rows)
    end

    def addons_keyboard(item_id, selected_addons)
      rows = MenuService.addons.map do |addon|
        mark = selected_addons.include?(addon.id) ? "✓ " : ""
        [ button("#{mark}#{addon.name} +#{addon.formatted_price}", "addon_#{item_id}_#{addon.id}") ]
      end
      inline(rows + [ [ button("✔ Готово", "addons_done_#{item_id}") ] ])
    end

    def quick_reorder_keyboard(order_id)
      inline([ [ button("🔄 Повторить заказ", "reorder_#{order_id}") ], [ button("✏ Изменить", "menu_main") ] ])
    end

    def popular_keyboard(items = MenuService.popular_items)
      inline(items.each_slice(2).map { |slice| slice.map { |item| button("#{item.name} — #{item.formatted_price}", "item_#{item.id}") } })
    end

    def upsell_keyboard(item)
      inline([ [ button("➕ Добавить", "upsell_add_#{item.id}"), button("Нет спасибо", "upsell_skip") ] ])
    end

    def barista_panel_keyboard
      inline([ [ button("📋 Очередь заказов", "barista_queue") ], [ button("☕ В работе", "barista_in_progress") ] ])
    end

    def barista_claim_keyboard(order_id) = inline([ [ button("✅ Принять в работу", "barista_claim_#{order_id}") ] ])
    def barista_complete_keyboard(order_id) = inline([ [ button("✅ Готов", "barista_complete_#{order_id}") ] ])

    def barista_queue_keyboard(orders)
      inline(orders.map do |order|
        wait = ((Time.current - order.created_at) / 60).round
        indicator = if wait > 10 then "🔴"
        elsif wait > 5 then "⚠"
        else ""
        end
        [ button("##{order.id} #{indicator}", "barista_detail_#{order.id}") ]
      end)
    end

    def barista_action_keyboard(order_id)
      inline([
        [ button("✅ Принять", "barista_claim_#{order_id}"), button("☕ Готов", "barista_complete_#{order_id}") ],
        [ button("⬅ Назад", "barista_queue") ]
      ])
    end

    # Shown when the client already has an active order but wants another one
    def preorder_keyboard = inline([ [ button("🛒 Сделать предзаказ", "preorder_start") ] ])
  end
end
