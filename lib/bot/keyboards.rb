# frozen_string_literal: true

# Bot Keyboards
# Centralized keyboard layouts for the bot

module CoffeeBot
  module Bot
    # Main menu keyboard
    def self.main_menu
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '☕ Кофе', callback_data: 'menu_coffee'),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🍰 Десерты', callback_data: 'menu_desserts')
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🍵 Чай', callback_data: 'menu_tea'),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавки', callback_data: 'menu_addons')
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔥 Популярное', callback_data: 'menu_popular')
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🛒 Корзина', callback_data: 'menu_cart'),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '📦 Мои заказы', callback_data: 'menu_orders')
          ]
        ]
      )
    end

    # Category keyboard with items
    def self.category_keyboard(category, items, back_button: true)
      buttons = items.map do |item|
        # Show "from X KGS" for items with sizes, regular price otherwise
        price_text = if item.has_sizes?
          "от #{item.formatted_price_for_size('small')}"
        else
          item.formatted_price
        end
        
        [Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "#{item.name} — #{price_text}",
          callback_data: "item_#{item.id}"
        )]
      end
      
      navigation = []
      navigation << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '⬅ Назад', callback_data: 'menu_back')]
      navigation << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🛒 Корзина', callback_data: 'menu_cart')] if back_button
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons + navigation)
    end

    # Item detail keyboard (for items without sizes)
    def self.item_keyboard(item, cart_count: 0)
      buttons = [
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить в корзину', callback_data: "add_item_#{item.id}")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавки', callback_data: "addons_#{item.id}")],
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔙 Назад', callback_data: 'menu_back')]
      ]
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    # Size selector keyboard for drinks
    # @param item [MenuItem] Menu item with sizes
    # @return [Telegram::Bot::Types::InlineKeyboardMarkup]
    def self.size_keyboard(item)
      size_buttons = item.size_options.map do |opt|
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "#{opt[:label]} #{opt[:formatted_price]}",
          callback_data: "size_#{item.id}_#{opt[:size]}"
        )
      end
      
      buttons = [
        size_buttons,  # All sizes in one row
        [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔙 Назад', callback_data: 'menu_back')]
      ]
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    # Quantity selector keyboard (after size selection or for items without sizes)
    # @param item_id [Integer] Menu item ID
    # @param size [String, nil] Selected size or nil
    # @return [Telegram::Bot::Types::InlineKeyboardMarkup]
    def self.quantity_keyboard(item_id, size = nil)
      # All quantity buttons in a single row
      buttons = (1..5).map do |qty|
        callback = size ? "qty_#{item_id}_#{size}_#{qty}" : "qty_#{item_id}_#{qty}"
        Telegram::Bot::Types::InlineKeyboardButton.new(
          text: qty.to_s,
          callback_data: callback
        )
      end
      
      back_callback = size ? "size_#{item_id}" : "item_#{item_id}"
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          buttons,
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔙 Назад', callback_data: back_callback)]
        ]
      )
    end

    # Cart keyboard
    def self.cart_keyboard
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить еще', callback_data: 'cart_add'),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🗑 Очистить', callback_data: 'cart_clear')
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '✏ Изменить', callback_data: 'cart_edit')
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '💳 Оплатить', callback_data: 'cart_checkout')
          ]
        ]
      )
    end

    # Confirmation keyboard
    def self.confirm_keyboard
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Да', callback_data: 'confirm_yes'),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '❌ Нет', callback_data: 'confirm_no')
          ]
        ]
      )
    end

    # Navigation keyboard
    def self.navigation_keyboard(back_action: 'menu_back', cart_action: nil)
      buttons = []
      buttons << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '⬅ Назад', callback_data: back_action)]
      buttons << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🏠 Главное меню', callback_data: 'menu_main')] if back_action != 'menu_back'
      buttons << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🛒 Корзина', callback_data: 'menu_cart')] if cart_action
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [buttons].compact)
    end

    # Add-ons keyboard
    def self.addons_keyboard(item_id, selected_addons)
      all_addons = Services::MenuService.addons
      
      buttons = all_addons.map do |addon|
        is_selected = selected_addons.include?(addon.id)
        text = is_selected ? "✓ #{addon.name} +#{addon.formatted_price}" : "#{addon.name} +#{addon.formatted_price}"
        
        [Telegram::Bot::Types::InlineKeyboardButton.new(
          text: text,
          callback_data: "addon_#{item_id}_#{addon.id}"
        )]
      end
      
      buttons << [Telegram::Bot::Types::InlineKeyboardButton.new(text: '✔ Готово', callback_data: "addons_done_#{item_id}")]
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    # Quick reorder keyboard
    def self.quick_reorder_keyboard(order_id)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '🔄 Повторить заказ', callback_data: "reorder_#{order_id}")
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '✏ Изменить', callback_data: 'menu_main')
          ]
        ]
      )
    end

    # Popular items keyboard
    def self.popular_keyboard
      popular_items = Services::MenuService.popular_items
      
      buttons = popular_items.each_slice(2).map do |item_slice|
        item_slice.map do |item|
          Telegram::Bot::Types::InlineKeyboardButton.new(
            text: "#{item.name} — #{item.formatted_price}",
            callback_data: "item_#{item.id}"
          )
        end
      end
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    # Upsell keyboard
    def self.upsell_keyboard(item)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить', callback_data: "upsell_add_#{item.id}"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: 'Нет спасибо', callback_data: 'upsell_skip')
          ]
        ]
      )
    end

    # Barista queue keyboard
    def self.barista_queue_keyboard(orders)
      buttons = orders.map do |order|
        wait_time = ((Time.now.utc - order.created_at) / 60).round
        wait_indicator = wait_time > 10 ? '🔴' : (wait_time > 5 ? '⚠' : '')
        
        [Telegram::Bot::Types::InlineKeyboardButton.new(
          text: "##{order.id} #{wait_indicator}",
          callback_data: "barista_detail_#{order.id}"
        )]
      end
      
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    end

    # Barista order action keyboard
    def self.barista_action_keyboard(order_id)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(
        inline_keyboard: [
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Принять', callback_data: "barista_claim_#{order_id}"),
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '☕ Готов', callback_data: "barista_complete_#{order_id}")
          ],
          [
            Telegram::Bot::Types::InlineKeyboardButton.new(text: '⬅ Назад', callback_data: 'barista_queue')
          ]
        ]
      )
    end
  end
end
