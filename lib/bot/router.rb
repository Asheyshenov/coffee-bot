# frozen_string_literal: true

# Bot Router
# Dispatches incoming Telegram messages to appropriate handlers

require_relative '../../config/boot'
require_relative '../models/order_status'
require_relative 'keyboards'
require 'telegram/bot'

module CoffeeBot
  module Bot
    class Router
      # Order statuses that mean the payment has already been received
      PAID_STATUSES = [OrderStatus::PAID, OrderStatus::IN_PROGRESS, OrderStatus::READY].freeze

      BARISTA_ACCESS_DENIED = '⛔ У вас нет доступа к панели баристы.'
      UNKNOWN_INPUT_TEXT = "Я вас не понял 🤔\nИспользуйте кнопки меню или /order, чтобы сделать заказ. /help — справка."
      INVALID_QTY_TEXT = 'Некорректное количество'

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

        # NB: a callback query can be answered only once (Telegram rejects the second
        # answer), so handlers answer it themselves via answer_callback when they need
        # a toast/alert; the ensure below answers the rest to remove the loading state.
        case data
        when /^category_(.+)$/
          handle_category_select(callback, Regexp.last_match(1))
        when /^item_(\d+)$/
          handle_item_select(callback, Regexp.last_match(1).to_i)
        when /^qty_(\d+)_(\d+)$/
          handle_qty_select(callback, Regexp.last_match(1).to_i, Regexp.last_match(2).to_i)
        when /^cart_(add|checkout|clear|back|edit)$/
          handle_cart_action(callback, Regexp.last_match(1))
        when /^cart_remove_(\d+)$/
          handle_cart_remove(callback, Regexp.last_match(1).to_i)
        when /^confirm_(yes|no)$/
          handle_confirm(callback, Regexp.last_match(1))
        when /^check_payment_(\d+)$/
          handle_check_payment(callback, Regexp.last_match(1).to_i)
        when /^barista_claim_(\d+)$/
          handle_barista_claim(callback, Regexp.last_match(1).to_i)
        when /^barista_complete_(\d+)$/
          handle_barista_complete(callback, Regexp.last_match(1).to_i)
        when /^refund_done_(\d+)$/
          handle_refund_done(callback, Regexp.last_match(1).to_i)
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
        # Pre-order handler
        when 'preorder_start'
          handle_preorder_start(callback)
        else
          log_debug('Unknown callback', data: data)
        end
      ensure
        # Stop the button spinner even if the handler did not answer or raised
        answer_callback(callback)
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

      def handle_order_start(message)
        user_id = message.from.id

        # Clear any existing draft first (user wants to make a new order)
        Draft.clear(user_id)

        # Check if user has active orders
        active_orders = Services::OrderService.active_orders_for_client(user_id)
        unless active_orders.empty?
          # Show message with pre-order button
          orders_list = active_orders.map do |order|
            items_summary = order.format_short_summary
            "##{order.id} (#{items_summary})"
          end.join("\n")
          
          text = "У вас уже есть активные заказы:\n#{orders_list}\n\nПожалуйста, дождитесь их завершения или оформите новый предзаказ."
          
          keyboard = Bot.preorder_keyboard
          
          bot.api.send_message(
            chat_id: user_id,
            text: text,
            reply_markup: keyboard
          )
          return
        end

        # Start order wizard
        Draft.clear(user_id)
        show_categories(message)
      end

      # Handle pre-order start (when user has active order but wants to make another)
      def handle_preorder_start(callback)
        user_id = callback.from.id

        # Start order wizard for pre-order
        Draft.clear(user_id)
        
        # Show the main menu keyboard
        keyboard = Bot.main_menu
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: '🛒 Предзаказ: выберите категорию:',
          reply_markup: keyboard
        )
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
        # Check authorization
        return unless authorize_barista(message)

        show_barista_panel(message)
      end

      def handle_cancel(message)
        user_id = message.from.id

        # Only unpaid orders are cancelled; paid ones stay (refund goes through the barista)
        active_orders = Services::OrderService.active_orders_for_client(user_id)
        outcomes = active_orders.map do |order|
          outcome = Services::OrderService.cancel_by_client(order) do |sync_result|
            # Last-chance sync settled the order (paid, or a payment problem): nobody else
            # announces it, so send the regular payment notifications (baristas + client)
            notify_payment_result(order, sync_result, notify_client: true)
          end
          [order, outcome]
        end

        # Clear draft
        Draft.clear(user_id)

        # Build response message
        if outcomes.empty?
          text = '❌ Корзина очищена. Нет активных заказов для отмены.'
        else
          parts = outcomes.map { |order, outcome| cancel_outcome_text(order, outcome) }
          if outcomes.any? { |_, outcome| %i[cancelled cancelled_locally].include?(outcome) }
            parts << "\nНачните заново с /order"
          end
          text = parts.join("\n")
        end

        bot.api.send_message(
          chat_id: user_id,
          text: text
        )
      end

      # User-facing text for a Services::OrderService.cancel_by_client outcome
      def cancel_outcome_text(order, outcome)
        case outcome
        when :cancelled
          "❌ Заказ ##{order.id} отменён."
        when :cancelled_locally
          "❌ Заказ ##{order.id} отменён, но счёт не удалось отменить в платёжной системе. " \
            'Пожалуйста, не оплачивайте его.'
        when :paid_now, :already_paid
          "✅ Заказ ##{order.id} уже оплачен и стоит в очереди. Для отмены обратитесь к баристе."
        when :in_progress
          "☕ Заказ ##{order.id} уже готовится. Для отмены обратитесь к баристе."
        when :payment_problem
          payment_problem_text(order)
        else
          "ℹ️ Заказ ##{order.id} уже нельзя отменить (статус: #{order.display_status})."
        end
      end

      def handle_help(message)
        user_id = message.from.id

        text = <<~TEXT
          📖 Справка по командам:
          
          /start - Начать работу с ботом
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

        unless draft
          bot.api.send_message(chat_id: user_id, text: UNKNOWN_INPUT_TEXT)
          return
        end

        state = draft.state
        step = state['step']

        case step
        when 'add_comment'
          # Stickers, photos, voice messages have no text
          comment = message.text.to_s.strip
          if comment.empty?
            bot.api.send_message(chat_id: user_id, text: 'Отправьте комментарий текстом или нажмите «⏭ Пропустить».')
            return
          end

          # Save comment (truncated to the column size) and show confirmation
          draft.set_comment(comment)
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

        # Build keyboard with size-aware pricing
        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: items.map do |item|
            # Show "от X KGS" for items with sizes, regular price otherwise
            price_text = if item.has_sizes?
              "от #{item.formatted_price_for_size('small')}"
            else
              item.formatted_price
            end
            
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: "#{item.name} — #{price_text}",
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
          text: "☕ #{category}:\nВыберите товар:",
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

        # If item has sizes, show size selector first
        if item.has_sizes?
          handle_size_menu(callback, item_id)
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

        # Add to cart (crafted callbacks may carry any quantity)
        draft = Draft.get_or_create(user_id)
        unless draft.add_item(item, qty)
          answer_callback(callback, text: INVALID_QTY_TEXT, show_alert: true)
          return
        end
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
        when 'edit'
          # Show cart items with remove buttons
          handle_cart_edit(callback)
        end
      end

      # Show cart items with remove buttons
      def handle_cart_edit(callback)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        if draft.nil? || draft.items.empty?
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: '🛒 Корзина пуста'
          )
          return
        end
        
        keyboard = Bot.cart_edit_keyboard(draft)
        
        text = "✏ Редактирование корзины:\n\nНажмите на товар, чтобы удалить его."
        
        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: text,
          reply_markup: keyboard
        )
      end

      # Remove item from cart by index
      def handle_cart_remove(callback, index)
        user_id = callback.from.id
        draft = Draft.for_user(user_id)
        
        if draft && draft.items.length > index
          removed_item = draft.items[index]
          draft.remove_item(index)
          
          if draft.items.empty?
            bot.api.edit_message_text(
              chat_id: user_id,
              message_id: callback.message.message_id,
              text: "🗑 Удалено: #{removed_item['display_name']}\n\nКорзина теперь пуста."
            )
          else
            keyboard = Bot.cart_edit_keyboard(draft)
            bot.api.edit_message_text(
              chat_id: user_id,
              message_id: callback.message.message_id,
              text: "🗑 Удалено: #{removed_item['display_name']}\n\nПродолжайте редактирование или нажмите 'Назад'.",
              reply_markup: keyboard
            )
          end
        end
      end

      def show_confirmation(message)
        user_id = message.from.id
        draft = Draft.for_user(user_id)

        return unless draft

        send_confirmation(user_id, draft)
      end

      # Confirmation screen. The cart is re-checked against the menu first, so the
      # client confirms current prices and only available items.
      #
      # @param changes [Hash] Result of Draft#sync_with_menu! if the caller already ran it
      def send_confirmation(chat_id, draft, changes = draft.sync_with_menu!)
        if draft.empty?
          bot.api.send_message(chat_id: chat_id, text: "#{menu_changes_text(changes)}🛒 Корзина пуста. /order для нового заказа.")
          return
        end

        text = <<~TEXT
          #{menu_changes_text(changes)}📋 Подтверждение заказа:

          #{draft.format_cart}

          💬 Комментарий: #{draft.comment || '-'}

          Подтвердить заказ?
        TEXT

        bot.api.send_message(
          chat_id: chat_id,
          text: text,
          reply_markup: Bot.confirm_keyboard
        )
      end

      # Note about cart lines changed by Draft#sync_with_menu!, empty if nothing changed
      def menu_changes_text(changes)
        lines = []
        lines << "⚠️ Больше нет в наличии: #{changes[:removed].join(', ')}" if changes[:removed].any?
        lines << "⚠️ Изменилась цена: #{changes[:repriced].join(', ')}" if changes[:repriced].any?
        lines.empty? ? '' : "#{lines.join("\n")}\n\n"
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

        # A second tap on "✅ Да" after the order was created finds no draft
        draft = Draft.for_user(user_id)
        if draft.nil? || draft.empty?
          answer_callback(callback, text: 'Корзина пуста или заказ уже оформлен. /order для нового заказа.', show_alert: true)
          return
        end

        # Prices or availability changed since the confirmation screen: confirm again
        changes = draft.sync_with_menu!
        if changes[:removed].any? || changes[:repriced].any?
          send_confirmation(user_id, draft, changes)
          return
        end

        client = Client.find_or_create_from_message(callback)

        begin
          order = Services::OrderService.create_from_draft(draft, client)
          unless order
            bot.api.send_message(chat_id: user_id, text: '❌ Часть позиций больше недоступна. Проверьте корзину и оформите заказ заново.')
            return
          end

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
          # Details go to the log only: provider / internal messages are not for clients
          log_error('Failed to create order', user_id: user_id, error: "#{e.class}: #{e.message}")
          bot.api.send_message(
            chat_id: user_id,
            text: '❌ Не удалось создать счёт на оплату. Попробуйте ещё раз через минуту.'
          )
        end
      end

      def handle_skip_comment(callback)
        # Use chat_id from message, not from callback (to avoid "bots can't send to bots" error)
        chat_id = callback.message&.chat&.id || callback.from.id
        draft = Draft.for_user(chat_id)

        if draft
          draft.set_comment(nil)
          draft.set_step('confirm')
          send_confirmation(chat_id, draft)
        else
          answer_callback(callback, text: 'Корзина пуста. /order для нового заказа.')
        end
      end

      def handle_start_order_callback(callback)
        user_id = callback.from.id

        # Check if user has active order
        active = Services::OrderService.active_order_for_client(user_id)
        if active
          answer_callback(callback, text: "У вас уже есть активный заказ ##{active.id}", show_alert: true)
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
      end

      def handle_check_payment(callback, order_id)
        user_id = callback.from.id
        order = Order[order_id]

        unless order && order.telegram_user_id == user_id
          answer_callback(callback, text: 'Заказ не найден')
          return
        end

        # Sync status (not needed once the order is paid - StatusSyncer/callback got there first)
        result = {}
        unless PAID_STATUSES.include?(order.status)
          begin
            result = Services::OrderService.sync_payment_status(order)
          rescue StandardError => e
            log_error('Failed to check payment status', order_id: order.id, error: e.message)
            answer_callback(callback, text: '⚠️ Не удалось проверить оплату. Попробуйте чуть позже.')
            return
          end
          order.refresh

          # Only the caller that changed the order gets the flags (otherwise StatusSyncer /
          # callback already announced it), so baristas are told exactly once. The client
          # is answered right here, no separate message.
          notify_payment_result(order, result, notify_client: false)
        end

        case order.status
        when *PAID_STATUSES
          text = if order.status == OrderStatus::PAID
            "✅ Оплата подтверждена! Заказ ##{order.id} передан в работу."
          else
            "✅ Заказ ##{order.id} оплачен. Статус: #{order.display_status}."
          end
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: text
          )
        when OrderStatus::INVOICE_CREATED
          answer_callback(callback, text: '⏳ Оплата ещё не получена. Попробуйте чуть позже.')
        else
          # Closed order (expired / cancelled / error). A late payment keeps the order
          # closed and is refunded; a rejected payment (e.g. amount too low) ends in ERROR.
          text = if result[:payment_error]
            payment_problem_text(order)
          elsif result[:refund_required] || order.refund_required?
            "💸 Оплата по заказу ##{order.id} поступила #{late_payment_reason(result[:previous_status] || order.status)}. " \
              'Заказ не будет приготовлен, деньги вернём.'
          else
            "Заказ ##{order.id}: #{order.display_status}"
          end
          answer_callback(callback, text: text, show_alert: true)
        end
      end

      # === Barista Handlers ===

      def show_barista_panel(message)
        return unless authorize_barista(message)

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
        return unless authorize_barista(callback)

        case action
        when 'queue'
          show_barista_queue(callback)
        when 'in_progress'
          show_barista_in_progress(callback)
        when 'menu'
          show_barista_panel(callback)
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
        return unless authorize_barista(callback)

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
          answer_callback(callback, text: 'Не удалось принять заказ. Возможно, его уже взял другой бариста.')
        end
      end

      def handle_barista_complete(callback, order_id)
        return unless authorize_barista(callback)

        user_id = callback.from.id
        order = Order[order_id]

        # Only the barista who claimed the order may complete it
        unless order && order.assigned_to_barista_id == user_id
          answer_callback(callback, text: 'Заказ не найден или не принадлежит вам', show_alert: true)
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

      # Barista confirms that a late payment was returned to the client
      def handle_refund_done(callback, order_id)
        return unless authorize_barista(callback)

        order = Order[order_id]
        unless order&.mark_refunded!(callback.from.id)
          answer_callback(callback, text: 'Возврат уже отмечен или не требуется', show_alert: true)
          return
        end

        bot.api.edit_message_text(
          chat_id: callback.from.id,
          message_id: callback.message.message_id,
          text: "✅ Возврат по заказу ##{order.id} отмечен как выполненный. Клиент уведомлён."
        )
        @notifier.notify_refund_completed(order)
      end

      # === New Menu Navigation Handlers ===

      def handle_menu_category(callback, category_key)
        user_id = callback.from.id
        category_map = {
          'coffee' => '☕ Кофе',
          'desserts' => '🍰 Десерты',
          'tea' => '🍵 Чай',
          'addons' => '➕ Добавки'
        }
        category = category_map[category_key]
        items = Services::MenuService.items_by_category(category)
        
        if items.empty?
          answer_callback(callback, text: "В категории '#{category}' нет товаров")
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
          answer_callback(callback, text: 'Нет популярных товаров')
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
          # Show empty cart message in the chat (not just toast)
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "🛒 Корзина пуста\n\nДобавьте товары из меню."
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
          answer_callback(callback, text: 'У вас пока нет заказов')
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
          answer_callback(callback, text: 'Начните заказ сначала')
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
          answer_callback(callback, text: 'Начните заказ сначала')
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
          answer_callback(callback, text: 'Товар не найден')
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
          answer_callback(callback, text: 'Заказ не найден')
          return
        end
        
        # Create new draft from order items (same sizes; current prices; only available items)
        Draft.clear(user_id)
        draft = Draft.get_or_create(user_id)
        unavailable = []

        order.order_items.each do |order_item|
          menu_item = MenuItem[order_item.menu_item_id]
          if menu_item&.is_available
            draft.add_item_with_size(menu_item, order_item.size, order_item.qty)
          else
            unavailable << order_item.item_name
          end
        end

        note = unavailable.any? ? "\n\n⚠️ Больше нет в наличии: #{unavailable.join(', ')}" : ''

        if draft.empty?
          bot.api.edit_message_text(
            chat_id: user_id,
            message_id: callback.message.message_id,
            text: "😔 Не удалось повторить заказ ##{order.id}: позиций больше нет в меню.#{note}"
          )
          return
        end

        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "🔄 Заказ повторён!\n\n#{draft.format_cart}#{note}",
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
          answer_callback(callback, text: 'Товар не найден')
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
          answer_callback(callback, text: 'Товар не найден')
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
          answer_callback(callback, text: 'Товар не найден')
          return
        end
        
        # Add item with size to cart (crafted callbacks may carry any quantity)
        draft = Draft.get_or_create(user_id)
        unless draft.add_item_with_size(item, size, qty)
          answer_callback(callback, text: INVALID_QTY_TEXT, show_alert: true)
          return
        end

        added_qty = [qty, Draft::MAX_QTY_PER_LINE].min

        bot.api.edit_message_text(
          chat_id: user_id,
          message_id: callback.message.message_id,
          text: "✅ Добавлено: #{item.display_name_for_size(size)} x#{added_qty}\n\n#{draft.format_cart}",
          reply_markup: Bot.cart_keyboard
        )
      end

      # === Helpers ===

      # Answer a callback query at most once (Telegram rejects a second answer, so a
      # toast/alert sent after an earlier answer would never reach the user)
      #
      # @param callback [Telegram::Bot::Types::CallbackQuery] The callback query
      # @param text [String, nil] Optional toast/alert text
      # @param show_alert [Boolean] Show a modal alert instead of a toast
      # @return [Boolean] True if an answer was sent
      def answer_callback(callback, text: nil, show_alert: false)
        return false if @answered_callback_id == callback.id

        @answered_callback_id = callback.id
        params = { callback_query_id: callback.id }
        params[:text] = text if text
        params[:show_alert] = true if show_alert
        bot.api.answer_callback_query(**params)
        true
      rescue StandardError => e
        # Best effort: e.g. the query is too old after a slow handler. Never raise from here,
        # it is also called from an ensure block.
        log_error('Failed to answer callback query', callback_id: callback.id, error: e.message)
        false
      end

      # Allow barista-only actions for whitelisted baristas; deny everybody else
      #
      # @param update [Telegram::Bot::Types::Message, Telegram::Bot::Types::CallbackQuery]
      # @return [Boolean] True if the sender is a barista
      def authorize_barista(update)
        user_id = update.from.id
        return true if Services::AuthService.barista?(user_id)

        if update.is_a?(Telegram::Bot::Types::CallbackQuery)
          log_info('Unauthorized barista action', user_id: user_id, data: update.data)
          answer_callback(update, text: BARISTA_ACCESS_DENIED, show_alert: true)
        else
          log_info('Unauthorized barista action', user_id: user_id, text: update.text.to_s[0..50])
          bot.api.send_message(chat_id: user_id, text: BARISTA_ACCESS_DENIED)
        end
        false
      end

      # Notifications for a payment status change found by a sync started from the bot
      # (check payment button, /cancel). Only the caller that won the transition gets the
      # flags, so the bot announces it itself, same as StatusSyncer / callback: baristas get
      # the new order, the refund request (late payment) or the payment problem alert.
      #
      # @param order [Order] The order
      # @param result [Hash] Sync result, see MWallet::Service#sync_status
      # @param notify_client [Boolean] Also send the client the "payment received" message
      #   (false when the client is answered in place, e.g. the payment message is edited)
      def notify_payment_result(order, result, notify_client:)
        return unless result[:notify_barista] || result[:payment_error] || result[:refund_required]

        # A refund is announced in full: the client keeps a message about the money
        if notify_client || result[:refund_required]
          @notifier.notify_payment_result(order, result)
        elsif result[:payment_error]
          @notifier.notify_baristas_payment_problem(order,
            expected_amount: result[:expected_amount],
            paid_amount: result[:paid_amount]
          )
        else
          @notifier.notify_baristas_new_order(order)
        end
      rescue StandardError => e
        log_error('Failed to send payment notifications', order_id: order.id, error: e.message)
      end

      # Client text for a payment the provider reported but we could not accept
      # (order moved to ERROR, baristas have been alerted)
      def payment_problem_text(order)
        "⚠️ Оплата по заказу ##{order.id} не принята: сумма платежа не совпадает с суммой заказа. " \
          'Бариста проверит платёж и свяжется с вами.'
      end

      # "после истечения срока счёта" / "после отмены заказа"
      def late_payment_reason(previous_status)
        previous_status == OrderStatus::CANCELLED ? 'после отмены заказа' : 'после истечения срока счёта'
      end

      def main_keyboard
        Telegram::Bot::Types::ReplyKeyboardMarkup.new(
          keyboard: [
            [{ text: '🛒 Сделать предзаказ' }],
            [{ text: '📦 Мои заказы' }, { text: '❓ Помощь' }]
          ],
          resize_keyboard: true,
          one_time_keyboard: false
        )
      end
    end
  end
end
