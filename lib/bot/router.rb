# frozen_string_literal: true

# Bot Router
# Dispatches incoming Telegram messages to appropriate handlers

require_relative '../../config/boot'
require_relative 'keyboards'
require 'telegram/bot'

module CoffeeBot
  module Bot
    class Router
      attr_reader :bot, :notifier

      def initialize(bot)
        @bot = bot
        @notifier = Services::Notifier.new(bot)
      end

      # Main run loop
      def run
        log_info('Bot router started')

        bot.listen do |message|
          handle_message(message)
        rescue StandardError => e
          log_error('Error handling message', error: e.message, backtrace: e.backtrace&.first(3))
        end
      end

      private

      # Handle incoming message
      def handle_message(message)
        case message
        when Telegram::Bot::Types::Message
          handle_text_message(message)
        when Telegram::Bot::Types::CallbackQuery
          handle_callback(message)
        else
          log_debug('Unknown message type', type: message.class)
        end
      end

      # Handle text messages (commands and regular messages)
      def handle_text_message(message)
        user_id = message.from.id
        text = message.text.to_s.strip

        log_debug('Received message', user_id: user_id, text: text[0..50])

        # Handle commands and keyboard button text
        case text
        when '/start'
          handle_start(message)
        when '/menu', '📋 Меню'
          handle_menu(message)
        when '/order', '🛒 Сделать предзаказ'
          handle_order_start(message)
        when '/my_orders', '📦 Мои заказы'
          handle_my_orders(message)
        when '/barista'
          handle_barista_panel(message)
        when '/cancel'
          handle_cancel(message)
        when '/help', '❓ Помощь'
          handle_help(message)
        else
          # Handle wizard flow or unknown command
          handle_wizard_input(message)
        end
      end

      # Handle callback queries (inline button clicks)
      def handle_callback(callback)
        user_id = callback.from.id
        data = callback.data

        log_debug('Received callback', user_id: user_id, data: data)

        # Answer callback to remove loading state
        bot.api.answer_callback_query(callback_query_id: callback.id)

        case data
        when /^category_(.+)$/
          handle_category_select(callback, Regexp.last_match(1))
        when /^item_(\d+)$/
          handle_item_select(callback, Regexp.last_match(1).to_i)
        when /^qty_(\d+)_(\d+)$/
          handle_qty_select(callback, Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
        when /^cart_(add|checkout|clear|back)$/
          handle_cart_action(callback, Regexp.last_match(1))
        when /^confirm_(yes|no)$/
          handle_confirm(callback, Regexp.last_match(1))
        when /^check_payment_(\d+)$/
          handle_check_payment(callback, Regexp.last_match(1).to_i)
        when /^barista_claim_(\d+)$/
          handle_barista_claim(callback, Regexp.last_match(1).to_i)
        when /^barista_complete_(\d+)$/
          handle_barista_complete(callback, Regexp.last_match(1).to_i)
        when /^barista_(queue|in_progress|menu)$/
          handle_barista_action(callback, Regexp.last_match(1))
        when 'skip_comment'
          handle_skip_comment(callback)
        when 'start_order'
          handle_start_order_callback(callback)
        # New menu navigation handlers
        when /^menu_(coffee|desserts|tea|addons)$/
          handle_menu_category(callback, Regexp.last_match(1))
        when 'menu_popular'
          handle_menu_popular(callback)
        when 'menu_cart'
          handle_menu_cart(callback)
        when 'menu_orders'
          handle_menu_orders(callback)
        when 'menu_back'
          handle_menu_back(callback)
        when 'menu_main'
          handle_menu_main(callback)
        when /^addon_(\d+)_(\d+)$/
          handle_addon_toggle(callback, Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
        when /^addons_done_(\d+)$/
          handle_addons_done(callback, Regexp.last_match(1).to_i)
        when /^add_item_(\d+)$/
          handle_add_item(callback, Regexp.last_match(1).to_i)
        when /^reorder_(\d+)$/
          handle_quick_reorder(callback, Regexp.last_match(1).to_i)
        when /^upsell_(add|skip)_(\d+)?$/
          handle_upsell(callback, Regexp.last_match(1), Regexp.last_match(2)&.to_i)
        # Size selection handlers
        when /^size_(\d+)$/
          handle_size_menu(callback, Regexp.last_match(1).to_i)
        when /^size_(\d+)_(small|medium|large)$/
          handle_size_select(callback, Regexp.last_match(1).to_i, Regexp.last_match(2))
        when /^qty_(\d+)_(small|medium|large)_(\d+)$/
          handle_qty_with_size(callback, Regexp.last_match(1).to_i, Regexp.last_match(2), Regexp.last_match(3).to_i)
        else
          log_debug('Unknown callback', data: data)
        end
      end

      # === Command Handlers ===

      def handle_start(message)
        user_id = message.from.id
        username = message.from.first_name

        # Create or update client
        client = Client.find_or_create_from_message(message)

        # Clear any existing draft
        Draft.clear(user_id)

        # Send welcome message with keyboard
        text = <<~TEXT
          Привет, #{username}! 👋
          
          Добро пожаловать в Coffee Bot!
          Я помогу вам заказать вкусный кофе.
          
          Выберите действие:
        TEXT

        keyboard = main_keyboard

        bot.api.send_message(
          chat_id: user_id,
          text: text,
          reply_markup: keyboard
        )
      end

      def handle_menu(message)
        user_id = message.from.id
        menu_text = Services::MenuService.format_menu

        # Add "Make preorder" button under menu
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [Telegram::Bot::Types::InlineKeyboardButton.new(text: '🛒 Сделать предзаказ', callback_data: 'start_order')]
          ]
        )

        bot.api.send_message(
          chat_id: user_id,
          text: menu_text,
          parse_mode: 'HTML',
          reply_markup: keyboard
        )
      end

      def handle_order_start(message)
        user_id = message.from.id

        # Check if user has active order
        active = Services::OrderService.active_order_for_client(user_id)
        if active
          bot.api.send_message(
            chat_id: user_id,
            text: "У вас уже есть активный заказ ##{active.id}. Дождитесь его завершения."
          )
          return
        end

        # Start order wizard
        Draft.clear(user_id)
        show_categories(message)
      end

      def handle_my_orders(message)
        user_id = message.from.id
        orders = Services::OrderService.client_orders(user_id, limit: 5)

        if orders.empty?
          bot.api.send_message(chat_id: user_id, text: 'У вас пока нет заказов.')
          return
        end

        text = "📋 Ваши последние заказы:\n\n"
        orders.each do |order|
          text += "##{order.id} - #{order.display_status} - #{order.formatted_total}\n"
          text += "   #{order.created_at.strftime('%d.%m %H:%M')}\n\n"
        end

        bot.api.send_message(chat_id: user_id, text: text)
      end

      def handle_barista_panel(message)
        user_id = message.from.id

        # Check authorization
        unless Services::AuthService.barista?(user_id)
          bot.api.send_message(
            chat_id: user_id,
            text: '⛔ У вас нет доступа к панели баристы.'
          )
          return
        end

        show_barista_panel(message)
      end

      def handle_cancel(message)
        user_id = message.from.id

        # Clear draft
        Draft.clear(user_id)

        bot.api.send_message(
          chat_id: user_id,
          text: '❌ Заказ отменён. Начните заново с /order'
        )
      end

      def handle_help(message)
        user_id = message.from.id

        text = <<~TEXT
          📖 Справка по командам:
          
          /start - Начать работу с ботом
          /menu - Посмотреть меню
          /order - Сделать заказ
          /my_orders - Мои заказы
          /cancel - Отменить текущий заказ
          /help - Эта справка
          
          💡 Чтобы сделать заказ:
          1. Нажмите /order
          2. Выберите категорию
          3. Выберите напиток
          4. Укажите количество
          5. Перейдите в корзину
          6. Оплатите заказ
        TEXT

        if Services::AuthService.barista?(user_id)
          text += "\n\n🔧 Команды баристы:\n/barista - Панель баристы"
        end

        bot.api.send_message(chat_id: user_id, text: text)
      end

      # === Wizard Handlers ===

      def handle_wizard_input(message)
        user_id = message.from.id
        draft = Draft.for_user(user_id)

        return unless draft

        state = draft.state
        step = state['step']

        case step
        when 'add_comment'
          # Save comment and show confirmation
          draft.set_comment(message.text[0..200])
          draft.set_step('confirm')
          show_confirmation(message)
        else
          # Unknown step or no active wizard
          bot.api.send_message(
            chat_id: user_id,
            text: 'Я вас не понял. Используйте /order для нового заказа.'
          )
        end
      end

      def show_categories(message)
        user_id = message.from.id
        categories = Services::MenuService.categories

        if categories.empty?
          bot.api.send_message(chat_id: user_id, text: 'Меню пока пустое.')
          return
        end

        # Update draft step
        Draft.update_state(user_id, 'step' => 'select_category')

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: categories.map do |cat|
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: cat,
              callback_data: "category_#{cat}"
            )]
          end
        )

        bot.api.send_message(
          chat_id: user_id,
          text: '☕ Выберите категорию:',
          reply_markup: keyboard
        )
      end

      def handle_category_select(callback, category)
        user_id = callback.from.id
        items = Services::MenuService.items_by_category(category)

        if items.empty?
          bot.api.send_message(
            chat_id: user_id,
            text: "В категории '#{category}' нет доступных товаров."
          )
          return
        end

        # Update draft
        Draft.update_state(user_id, 'step' => 'select_item', 'category' => category)

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: items.map do |item|
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "#{item.name} - #{item.formatted_price}",
              callback_data: "item_#{item.id}"
            )]
          end + [[Telegram::Bot::Types::InlineKeyboardButton.new(
            text: '⬅️ Назад',
            callback_data: 'cart_back'
          )]]
        )

        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "☕ #{category}:\nВыберите напиток:",
          reply_markup: keyboard
        )
      end

      def handle_item_select(callback, item_id)
        user_id = callback.from.id
        item = Services::MenuService.find_item(item_id)

        unless item
          bot.api.send_message(chat_id: user_id, text: 'Товар не найден.')
          return
        end

        # Update draft
        Draft.update_state(user_id, 'step' => 'select_qty', 'selected_item_id' => item_id)

        # Show quantity selector
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: (1..5).map do |qty|
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: qty.to_s,
              callback_data: "qty_#{item_id}_#{qty}"
            )]
          end
        )

        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "#{item.name} - #{item.formatted_price}\nВыберите количество:",
          reply_markup: keyboard
        )
      end

      def handle_qty_select(callback, item_id, qty)
        user_id = callback.from.id
        item = Services::MenuService.find_item(item_id)

        unless item
          bot.api.send_message(chat_id: user_id, text: 'Товар не найден.')
          return
        end

        # Add to cart
        draft = Draft.get_or_create(user_id)
        draft.add_item(item, qty)
        draft.set_step('cart')

        # Show cart
        show_cart(callback)
      end

      def show_cart(callback)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)

        unless draft && !draft.empty?
          bot.api.send_message(chat_id: user_id, text: 'Корзина пуста.')
          return
        end

        cart_text = "🛒 Ваша корзина:\n\n#{draft.format_cart}"

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(text: '➕ Добавить', callback_data: 'cart_add'),
              Telegram::Bot::Types::InlineKeyboardButton.new(text: '🗑 Очистить', callback_data: 'cart_clear')
            ],
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Оформить', callback_data: 'cart_checkout')
            ]
          ]
        )

        if callback.message
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: cart_text,
            reply_markup: keyboard
          )
        else
          bot.api.send_message(
            chat_id: user_id,
            text: cart_text,
            reply_markup: keyboard
          )
        end
      end

      def handle_cart_action(callback, action)
        user_id = callback.from.id

        case action
        when 'add'
          show_categories(callback)
        when 'clear'
          Draft.clear(user_id)
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: '🗑 Корзина очищена. /order для нового заказа.'
          )
        when 'checkout'
          draft = Draft.for_user(user_id)
          if draft && !draft.empty?
            # Ask for comment with skip button
            draft.set_step('add_comment')
            keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
              inline_keyboard: [
                [Telegram::Bot::Types::InlineKeyboardButton.new(text: '⏭ Пропустить', callback_data: 'skip_comment')]
              ]
            )
            bot.api.edit_message_text(
              chat_id: user_id,
              message_id: callback.message.message_id,
              text: '💬 Добавьте комментарий к заказу (или нажмите "Пропустить"):',
              reply_markup: keyboard
            )
          end
        when 'back'
          show_categories(callback)
        end
      end

      def show_confirmation(message)
        user_id = message.from.id
        draft = Draft.for_user(user_id)

        return unless draft

        text = <<~TEXT
          📋 Подтверждение заказа:
          
          #{draft.format_cart}
          
          💬 Комментарий: #{draft.comment || '-'}
          
          Подтвердить заказ?
        TEXT

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Да', callback_data: 'confirm_yes'),
              Telegram::Bot::Types::InlineKeyboardButton.new(text: '❌ Нет', callback_data: 'confirm_no')
            ]
          ]
        )

        bot.api.send_message(
          chat_id: user_id,
          text: text,
          reply_markup: keyboard
        )
      end

      def handle_confirm(callback, answer)
        user_id = callback.from.id

        if answer == 'no'
          Draft.clear(user_id)
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: '❌ Заказ отменён. /order для нового заказа.'
          )
          return
        end

        # Create order
        draft = Draft.for_user(user_id)
        client = Client.find_or_create_from_message(callback)

        begin
          order = Services::OrderService.create_from_draft(draft, client)

          # Create invoice
          invoice_data = Services::OrderService.create_invoice(order)

          # Clear draft
          Draft.clear(user_id)

          # Notify client
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "✅ Заказ ##{order.id} создан!"
          )

          # Send payment QR
          @notifier.send_payment_qr(order, invoice_data)

        rescue StandardError => e
          log_error('Failed to create order', error: e.message)
          bot.api.send_message(
            chat_id: user_id,
            text: "❌ Ошибка при создании заказа: #{e.message}"
          )
        end
      end

      def handle_skip_comment(callback)
        # Use chat_id from message, not from callback (to avoid "bots can't send to bots" error)
        chat_id = callback.message&.chat&.id || callback.from.id
        draft = Draft.for_user(chat_id)

        if draft
          draft.set_comment('-')
          draft.set_step('confirm')

          # Show confirmation directly with chat_id
          text = <<~TEXT
            📋 Подтверждение заказа:
            
            #{draft.format_cart}
            
            💬 Комментарий: -
            
            Подтвердить заказ?
          TEXT

          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '✅ Да', callback_data: 'confirm_yes'),
                Telegram::Bot::Types::InlineKeyboardButton.new(text: '❌ Нет', callback_data: 'confirm_no')
              ]
            ]
          )

          bot.api.send_message(
            chat_id: chat_id,
            text: text,
            reply_markup: keyboard
          )
        end

        bot.api.answer_callback_query(callback_query_id: callback.id)
      end

      def handle_start_order_callback(callback)
        user_id = callback.from.id

        # Check if user has active order
        active = Services::OrderService.active_order_for_client(user_id)
        if active
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: "У вас уже есть активный заказ ##{active.id}",
            show_alert: true
          )
          return
        end

        # Start order wizard
        Draft.clear(user_id)

        # Show the new main menu keyboard
        keyboard = Bot.main_menu

        bot.api.send_message(
          chat_id: user_id,
          text: '🏠 Главное меню:',
          reply_markup: keyboard
        )
        bot.api.answer_callback_query(callback_query_id: callback.id)
      end

      def handle_check_payment(callback, order_id)
        user_id = callback.from.id
        order = Order[order_id]

        unless order && order.telegram_user_id == user_id
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Заказ не найден'
          )
          return
        end

        # Sync status
        if Services::OrderService.sync_payment_status(order)
          order.refresh

          if order.status == OrderStatus::PAID
            bot.api.edit_message_text(
              chat_id: user_id,
              message_id: callback.message.message_id,
              text: "✅ Оплата подтверждена! Заказ ##{order.id} передан в работу."
            )

            # Notify baristas
            @notifier.notify_baristas_new_order(order)
          else
            bot.api.answer_callback_query(
              callback_query_id: callback.id,
              text: 'Оплата ещё не получена. Попробуйте позже.'
            )
          end
        else
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Статус не изменился'
          )
        end
      end

      # === Barista Handlers ===

      def show_barista_panel(message)
        user_id = message.from.id

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '📋 Очередь заказов',
              callback_data: 'barista_queue'
            )],
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '☕ В работе',
              callback_data: 'barista_in_progress'
            )],
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '📝 Меню',
              callback_data: 'barista_menu'
            )]
          ]
        )

        text = "🔧 Панель баристы\n\nВыберите действие:"

        if message.is_a?(Telegram::Bot::Types::CallbackQuery)
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: message.message.message_id,
            text: text,
            reply_markup: keyboard
          )
        else
          bot.api.send_message(
            chat_id: user_id,
            text: text,
            reply_markup: keyboard
          )
        end
      end

      def handle_barista_action(callback, action)
        user_id = callback.from.id

        case action
        when 'queue'
          show_barista_queue(callback)
        when 'in_progress'
          show_barista_in_progress(callback)
        when 'menu'
          handle_menu(callback)
        end
      end

      def show_barista_queue(callback)
        user_id = callback.from.id
        orders = Services::OrderService.barista_queue

        if orders.empty?
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: '✅ Очередь пуста! Нет ожидающих заказов.'
          )
          return
        end

        orders.each do |order|
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '✅ Принять в работу',
                callback_data: "barista_claim_#{order.id}"
              )]
            ]
          )

          bot.api.send_message(
            chat_id: user_id,
            text: order.format_for_barista,
            reply_markup: keyboard
          )
        end
      end

      def show_barista_in_progress(callback)
        user_id = callback.from.id
        orders = Services::OrderService.barista_in_progress(user_id)

        if orders.empty?
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: 'У вас нет заказов в работе.'
          )
          return
        end

        orders.each do |order|
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '✅ Готов',
                callback_data: "barista_complete_#{order.id}"
              )]
            ]
          )

          bot.api.send_message(
            chat_id: user_id,
            text: order.format_for_barista,
            reply_markup: keyboard
          )
        end
      end

      def handle_barista_claim(callback, order_id)
        user_id = callback.from.id

        if Services::OrderService.claim_order(order_id, user_id)
          order = Order[order_id]

          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "✅ Заказ ##{order_id} принят в работу!"
          )

          # Notify client
          @notifier.notify_order_preparing(order)
        else
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Не удалось принять заказ. Возможно, его уже взял другой бариста.'
          )
        end
      end

      def handle_barista_complete(callback, order_id)
        user_id = callback.from.id
        order = Order[order_id]

        unless order && order.assigned_to_barista_id == user_id
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Заказ не найден или не принадлежит вам'
          )
          return
        end

        if Services::OrderService.complete_order(order_id, user_id)
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "✅ Заказ ##{order_id} готов!"
          )

          # Notify client
          @notifier.notify_order_ready(order)
        end
      end

      # === New Menu Navigation Handlers ===

      def handle_menu_category(callback, category_key)
        user_id = callback.from.id
        category_map = {
          'coffee' => 'Кофе',
          'desserts' => 'Десерты',
          'tea' => 'Чай',
          'addons' => 'Добавки'
        }
        category = category_map[category_key]
        
        items = Services::MenuService.items_by_category(category)
        
        if items.empty?
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: "В категории '#{category}' нет товаров"
          )
          return
        end
        
        # Update draft step
        Draft.update_state(user_id, 'step' => 'select_item', 'category' => category)
        
        keyboard = Bot.category_keyboard(category, items)
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "☕ #{category}:\nВыберите товар:",
          reply_markup: keyboard
        )
      end

      def handle_menu_popular(callback)
        user_id = callback.from.id
        popular_items = Services::MenuService.popular_items
        
        if popular_items.empty?
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Нет популярных товаров'
          )
          return
        end
        
        keyboard = Bot.popular_keyboard
        
        text = "🔥 Популярные товары:\n\n"
        popular_items.each_with_index do |item, idx|
          text += "#{idx + 1}. #{item.name} — #{item.formatted_price}\n"
        end
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: text,
          reply_markup: keyboard
        )
      end

      def handle_menu_cart(callback)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        if draft.nil? || draft.items.empty?
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Корзина пуста'
          )
          return
        end
        
        keyboard = Bot.cart_keyboard
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "🛒 Ваша корзина:\n\n#{draft.format_cart}\n\n💰 Итого: #{draft.formatted_total}",
          reply_markup: keyboard
        )
      end

      def handle_menu_orders(callback)
        user_id = callback.from.id
        orders = Services::OrderService.client_orders(user_id, limit: 5)
        
        if orders.empty?
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'У вас пока нет заказов'
          )
          return
        end
        
        text = "📦 Ваши последние заказы:\n\n"
        orders.each do |order|
          text += "##{order.id} — #{order.display_status} — #{order.formatted_total}\n"
          text += "   📅 #{order.created_at.strftime('%d.%m %H:%M')}\n\n"
        end
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: text
        )
      end

      def handle_menu_back(callback)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        if draft && draft.current_step
          # Go back to previous step based on current state
          case draft.current_step
          when 'select_item'
            # Go back to main menu
            handle_menu_main(callback)
          when 'select_category'
            handle_menu_main(callback)
          else
            handle_menu_main(callback)
          end
        else
          handle_menu_main(callback)
        end
      end

      def handle_menu_main(callback)
        user_id = callback.from.id
        
        keyboard = Bot.main_menu
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: '🏠 Главное меню:',
          reply_markup: keyboard
        )
      end

      def handle_addon_toggle(callback, item_id, addon_id)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        unless draft
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Начните заказ сначала'
          )
          return
        end
        
        # Toggle addon in draft
        selected_addons = draft.state['selected_addons'] || []
        if selected_addons.include?(addon_id)
          selected_addons.delete(addon_id)
        else
          selected_addons << addon_id
        end
        
        Draft.update_state(user_id, 'selected_addons' => selected_addons)
        
        # Refresh keyboard
        keyboard = Bot.addons_keyboard(item_id, selected_addons)
        
        bot.api.edit_message_reply_markup(
          chat_id: user_id,
          message_id: callback.message.message_id,
          reply_markup: keyboard
        )
      end

      def handle_addons_done(callback, item_id)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        unless draft
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Начните заказ сначала'
          )
          return
        end
        
        # Proceed to quantity selection with selected addons
        selected_addons = draft.state['selected_addons'] || []
        
        # Store addons for this item
        Draft.update_state(user_id, 'addons_for_item' => { item_id => selected_addons })
        
        # Show quantity keyboard
        keyboard = Bot.quantity_keyboard(item_id)
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: '🔢 Выберите количество:',
          reply_markup: keyboard
        )
      end

      def handle_add_item(callback, item_id)
        user_id = callback.from.id
        item = Services::MenuService.find_item(item_id)
        
        unless item
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Товар не найден'
          )
          return
        end
        
        # Initialize draft if needed
        draft = Draft.get_or_create(user_id)
        Draft.update_state(user_id, 'step' => 'select_item', 'current_item_id' => item_id)
        
        # If item has sizes, show size selection first
        if item.has_sizes?
          handle_size_menu(callback, item_id)
        else
          # Show quantity selection directly for items without sizes
          keyboard = Bot.quantity_keyboard(item_id, nil)
          
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "#{item.name} — #{item.formatted_price}\n\n🔢 Выберите количество:",
            reply_markup: keyboard
          )
        end
      end

      def handle_quick_reorder(callback, order_id)
        user_id = callback.from.id
        order = Order[order_id]
        
        unless order && order.telegram_user_id == user_id
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Заказ не найден'
          )
          return
        end
        
        # Create new draft from order items
        Draft.clear(user_id)
        draft = Draft.get_or_create(user_id)
        
        order.items.each do |order_item|
          menu_item = MenuItem[order_item.menu_item_id]
          draft.add_item(menu_item, order_item.quantity) if menu_item
        end
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "🔄 Заказ повторён!\n\n#{draft.format_cart}\n\n💰 Итого: #{draft.formatted_total}",
          reply_markup: Bot.cart_keyboard
        )
      end

      def handle_upsell(callback, action, item_id)
        user_id = callback.from.id
        
        if action == 'add' && item_id
          # Add upsell item to cart
          draft = Draft.for_user(user_id)
          if draft
            menu_item = MenuItem[item_id]
            draft.add_item(menu_item, 1) if menu_item
          end
        end
        
        # Proceed to checkout
        handle_cart_action(callback, 'checkout')
      end

      # === Size Selection Handlers ===

      # Show size selection menu for drinks
      def handle_size_menu(callback, item_id)
        user_id = callback.from.id
        item = MenuItem[item_id]
        
        unless item
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Товар не найден'
          )
          return
        end
        
        unless item.has_sizes?
          # Item doesn't have sizes, go directly to quantity selection
          handle_item_select(callback, item_id)
          return
        end
        
        keyboard = Bot.size_keyboard(item)
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "☕ #{item.name}\n\n#{item.formatted_prices}\n\nВыберите размер:",
          reply_markup: keyboard
        )
      end

      # Handle size selection - show quantity selector
      def handle_size_select(callback, item_id, size)
        user_id = callback.from.id
        item = MenuItem[item_id]
        
        unless item
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Товар не найден'
          )
          return
        end
        
        # Store selected size in draft state
        Draft.update_state(user_id, 'current_item_id' => item_id, 'current_size' => size)
        
        keyboard = Bot.quantity_keyboard(item_id, size)
        
        size_label = MenuItem::SIZE_LABELS[size]
        price = item.formatted_price_for_size(size)
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "☕ #{item.name} (#{size_label}) — #{price}\n\nВыберите количество:",
          reply_markup: keyboard
        )
      end

      # Handle quantity selection with size
      def handle_qty_with_size(callback, item_id, size, qty)
        user_id = callback.from.id
        item = MenuItem[item_id]
        
        unless item
          bot.api.answer_callback_query(
            callback_query_id: callback.id,
            text: 'Товар не найден'
          )
          return
        end
        
        # Add item with size to cart
        draft = Draft.get_or_create(user_id)
        draft.add_item_with_size(item, size, qty)
        
        size_label = MenuItem::SIZE_LABELS[size]
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "✅ Добавлено: #{item.name} (#{size_label}) x#{qty}\n\n#{draft.format_cart}",
          reply_markup: Bot.cart_keyboard
        )
      end

      # === Helpers ===

      def main_keyboard
        Telegram::Bot::Types::ReplyKeyboardMarkup.new(
          keyboard: [
            [{ text: '📋 Меню' }, { text: '🛒 Сделать предзаказ' }],
            [{ text: '📦 Мои заказы' }, { text: '❓ Помощь' }]
          ],
          resize_keyboard: true,
          one_time_keyboard: false
        )
      end
    end
  end
end
