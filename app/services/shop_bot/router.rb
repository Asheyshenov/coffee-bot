# frozen_string_literal: true

module ShopBot
  # Handles one Telegram update (message or callback query) of a coffee shop's bot.
  # Runs inside the shop's tenant (set by ShopBot::ProcessUpdateJob).
  #
  #   ShopBot::Router.new(bot).handle(update.current_message)
  class Router
    # Order statuses that mean the payment has already been received
    PAID_STATUSES = [ OrderStatus::PAID, OrderStatus::IN_PROGRESS, OrderStatus::READY ].freeze

    PREORDER_BUTTON = "🛒 Сделать предзаказ"
    MY_ORDERS_BUTTON = "📦 Мои заказы"
    HELP_BUTTON = "❓ Помощь"

    BARISTA_ACCESS_DENIED = "⛔ У вас нет доступа к панели баристы."
    UNKNOWN_INPUT_TEXT = "Я вас не понял 🤔\nИспользуйте кнопки меню или /order, чтобы сделать заказ. /help — справка."
    INVALID_QTY_TEXT = "Некорректное количество"
    ITEM_NOT_FOUND = "Товар не найден"
    INVOICE_FAILED_TEXT = "❌ Не удалось создать счёт на оплату. Попробуйте ещё раз через минуту."

    # Main menu buttons -> category names (matched without emoji, see MenuItem.category_key)
    MENU_CATEGORIES = { "coffee" => "☕ Кофе", "desserts" => "🍰 Десерты", "tea" => "🍵 Чай", "addons" => "➕ Добавки" }.freeze

    attr_reader :bot

    # @param bot [Bot] the coffee shop's bot record (Telegram calls go through bot.api)
    def initialize(bot)
      @bot = bot
    end

    # @param update [Telegram::Bot::Types::Message, Telegram::Bot::Types::CallbackQuery, nil]
    #   Update#current_message; other update types are ignored
    def handle(update)
      case update
      when Telegram::Bot::Types::CallbackQuery then handle_callback(update)
      when Telegram::Bot::Types::Message then handle_message(update) if update.from
      else AppLog.info("Ignoring unsupported update", type: update.class.name)
      end
    end

    private

    def api = bot.api
    def notifier = @notifier ||= Notifier.new(bot)
    def tenant = @tenant ||= ActsAsTenant.current_tenant || bot.tenant

    # === Messages ===

    def handle_message(message)
      text = message.text.to_s.strip

      case command_of(text)
      when "/start" then handle_start(message)
      when "/order", PREORDER_BUTTON then handle_order_start(message)
      when "/my_orders", MY_ORDERS_BUTTON then handle_my_orders(message)
      when "/barista" then handle_barista_panel(message)
      when "/cancel" then handle_cancel(message)
      when "/help", HELP_BUTTON then handle_help(message)
      else handle_wizard_input(message)
      end
    end

    # "/start payload" -> "/start", "/order@shop_bot" -> "/order"; other text unchanged
    def command_of(text)
      return text unless text.start_with?("/")

      text.split(/\s/, 2).first.sub(/@\w+\z/, "")
    end

    # === Callback queries ===

    # A callback query can be answered only once (Telegram rejects the second answer),
    # so handlers answer it themselves via #answer_callback when they need a toast or
    # an alert; the ensure answers the rest to remove the loading state.
    def handle_callback(callback)
      dispatch_callback(callback, callback.data.to_s)
    ensure
      answer_callback(callback)
    end

    def dispatch_callback(callback, data)
      case data
      when /\Acategory_(.+)\z/ then handle_category_select(callback, $1)
      when /\Aitem_(\d+)\z/ then handle_item_select(callback, $1.to_i)
      when /\Aqty_(\d+)_(\d+)\z/ then handle_qty_select(callback, $1.to_i, $2.to_i)
      when /\Acart_(add|checkout|clear|back|edit)\z/ then handle_cart_action(callback, $1)
      when /\Acart_remove_(\d+)\z/ then handle_cart_remove(callback, $1.to_i)
      when /\Aconfirm_(yes|no)\z/ then handle_confirm(callback, $1)
      when /\Acheck_payment_(\d+)\z/ then handle_check_payment(callback, $1.to_i)
      when /\Abarista_claim_(\d+)\z/ then handle_barista_claim(callback, $1.to_i)
      when /\Abarista_complete_(\d+)\z/ then handle_barista_complete(callback, $1.to_i)
      when /\Arefund_done_(\d+)\z/ then handle_refund_done(callback, $1.to_i)
      when /\Abarista_(queue|in_progress|menu)\z/ then handle_barista_action(callback, $1)
      when "skip_comment" then handle_skip_comment(callback)
      when "start_order" then handle_start_order_callback(callback)
      when /\Amenu_(coffee|desserts|tea|addons)\z/ then handle_menu_category(callback, $1)
      when "menu_popular" then handle_menu_popular(callback)
      when "menu_cart" then handle_menu_cart(callback)
      when "menu_orders" then handle_menu_orders(callback)
      when "menu_back", "menu_main" then handle_menu_main(callback)
      when /\Aaddon_(\d+)_(\d+)\z/ then handle_addon_toggle(callback, $1.to_i, $2.to_i)
      when /\Aaddons_done_(\d+)\z/ then handle_addons_done(callback, $1.to_i)
      when /\Aadd_item_(\d+)\z/ then handle_add_item(callback, $1.to_i)
      when /\Areorder_(\d+)\z/ then handle_quick_reorder(callback, $1.to_i)
      when /\Aupsell_(add|skip)(?:_(\d+))?\z/ then handle_upsell(callback, $1, $2&.to_i)
      when /\Asize_(\d+)\z/ then handle_size_menu(callback, $1.to_i)
      when /\Asize_(\d+)_(small|medium|large)\z/ then handle_size_select(callback, $1.to_i, $2)
      when /\Aqty_(\d+)_(small|medium|large)_(\d+)\z/ then handle_qty_with_size(callback, $1.to_i, $2, $3.to_i)
      when "preorder_start" then handle_preorder_start(callback)
      else AppLog.info("Unknown callback", data: data[0, 64])
      end
    end

    # === Commands ===

    def handle_start(message)
      user_id = message.from.id
      Customer.from_telegram(message.from)
      Draft.clear(user_id)

      text = <<~TEXT
        Привет, #{message.from.first_name}! 👋

        Добро пожаловать в #{tenant.name}!
        Я помогу вам заказать вкусный кофе.

        Выберите действие:
      TEXT
      send_text(user_id, text, reply_markup: Keyboards.reply_keyboard)
    end

    def handle_order_start(message)
      user_id = message.from.id
      # The client starts a new order
      Draft.clear(user_id)

      active_orders = OrderService.active_orders_for_client(user_id)
      if active_orders.any?
        orders_list = active_orders.map { |order| "##{order.id} (#{order.format_short_summary})" }.join("\n")
        text = "У вас уже есть активные заказы:\n#{orders_list}\n\n" \
               "Пожалуйста, дождитесь их завершения или оформите новый предзаказ."
        send_text(user_id, text, reply_markup: Keyboards.preorder_keyboard)
        return
      end

      show_categories(message)
    end

    # The client has an active order but wants another one
    def handle_preorder_start(callback)
      Draft.clear(callback.from.id)
      edit(callback, "🛒 Предзаказ: выберите категорию:", reply_markup: Keyboards.main_menu)
    end

    def handle_my_orders(message)
      user_id = message.from.id
      orders = OrderService.client_orders(user_id, limit: 5)
      return send_text(user_id, "У вас пока нет заказов.") if orders.empty?

      text = +"📋 Ваши последние заказы:\n\n"
      orders.each do |order|
        text << "##{order.id} - #{order.display_status} - #{order.formatted_total}\n"
        text << "   #{local_time(order.created_at)}\n\n"
      end
      send_text(user_id, text)
    end

    def handle_barista_panel(message)
      show_barista_panel(message) if authorize_barista(message)
    end

    # Only unpaid orders are cancelled; paid ones stay (refunds go through the barista)
    def handle_cancel(message)
      user_id = message.from.id

      outcomes = OrderService.active_orders_for_client(user_id).map do |order|
        outcome = OrderService.cancel_by_client(order) do |sync_result|
          # The last-chance sync settled the order (paid, or a payment problem): nobody
          # else announces it, so send the regular payment notifications (baristas + client)
          notify_payment_result(order, sync_result, notify_client: true)
        end
        [ order, outcome ]
      end

      Draft.clear(user_id)

      text = if outcomes.empty?
        "❌ Корзина очищена. Нет активных заказов для отмены."
      else
        parts = outcomes.map { |order, outcome| cancel_outcome_text(order, outcome) }
        parts << "\nНачните заново с /order" if outcomes.any? { |_, outcome| outcome.in?(%i[cancelled cancelled_locally]) }
        parts.join("\n")
      end
      send_text(user_id, text)
    end

    # Client text for an OrderService.cancel_by_client outcome
    def cancel_outcome_text(order, outcome)
      case outcome
      when :cancelled
        "❌ Заказ ##{order.id} отменён."
      when :cancelled_locally
        "❌ Заказ ##{order.id} отменён, но счёт не удалось отменить в платёжной системе. " \
          "Пожалуйста, не оплачивайте его."
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
      text += "\n\n🔧 Команды баристы:\n/barista - Панель баристы" if AuthService.barista?(user_id)

      send_text(user_id, text)
    end

    # === Order wizard ===

    def handle_wizard_input(message)
      user_id = message.from.id
      draft = Draft.for_user(user_id)
      return send_text(user_id, UNKNOWN_INPUT_TEXT) unless draft

      if draft.current_step == "add_comment"
        # Stickers, photos and voice messages have no text
        comment = message.text.to_s.strip
        return send_text(user_id, "Отправьте комментарий текстом или нажмите «⏭ Пропустить».") if comment.empty?

        # Truncated to the orders.comment column size
        draft.set_comment(comment)
        draft.set_step("confirm")
        send_confirmation(user_id, draft)
      else
        send_text(user_id, "Я вас не понял. Используйте /order для нового заказа.")
      end
    end

    # Category list as a new message (for a command or a callback)
    def show_categories(update)
      user_id = update.from.id
      categories = MenuService.categories
      return send_text(user_id, "Меню пока пустое.") if categories.empty?

      Draft.update_state(user_id, "step" => "select_category")
      send_text(user_id, "☕ Выберите категорию:", reply_markup: Keyboards.categories_keyboard(categories))
    end

    def handle_category_select(callback, category)
      user_id = callback.from.id
      items = MenuService.items_by_category(category)
      return send_text(user_id, "В категории '#{category}' нет доступных товаров.") if items.empty?

      Draft.update_state(user_id, "step" => "select_item", "category" => category)
      edit(callback, "☕ #{category}:\nВыберите товар:", reply_markup: Keyboards.wizard_items_keyboard(items))
    end

    def handle_item_select(callback, item_id)
      user_id = callback.from.id
      item = available_item(item_id)
      return send_text(user_id, "#{ITEM_NOT_FOUND}.") unless item
      return show_size_menu(callback, item) if item.has_sizes?

      Draft.update_state(user_id, "step" => "select_qty", "selected_item_id" => item_id)
      edit(callback, "#{item.name} - #{item.formatted_price}\nВыберите количество:",
           reply_markup: Keyboards.wizard_quantity_keyboard(item_id))
    end

    def handle_qty_select(callback, item_id, qty)
      user_id = callback.from.id
      item = available_item(item_id)
      return send_text(user_id, "#{ITEM_NOT_FOUND}.") unless item

      # Crafted callbacks may carry any quantity: 0 is rejected, the line is capped
      draft = Draft.get_or_create(user_id)
      return answer_callback(callback, text: INVALID_QTY_TEXT, show_alert: true) unless draft.add_item(item, qty)

      draft.set_step("cart")
      show_cart(callback)
    end

    def show_cart(callback)
      user_id = callback.from.id
      draft = Draft.for_user(user_id)
      return send_text(user_id, "Корзина пуста.") if draft.nil? || draft.empty?

      edit(callback, "🛒 Ваша корзина:\n\n#{draft.format_cart}", reply_markup: Keyboards.wizard_cart_keyboard)
    end

    def handle_cart_action(callback, action)
      user_id = callback.from.id

      case action
      when "add", "back"
        show_categories(callback)
      when "clear"
        Draft.clear(user_id)
        edit(callback, "🗑 Корзина очищена. /order для нового заказа.")
      when "checkout"
        draft = Draft.for_user(user_id)
        return answer_callback(callback, text: "Корзина пуста. /order для нового заказа.") if draft.nil? || draft.empty?

        draft.set_step("add_comment")
        edit(callback, "💬 Добавьте комментарий к заказу (или нажмите \"Пропустить\"):",
             reply_markup: Keyboards.skip_comment_keyboard)
      when "edit"
        handle_cart_edit(callback)
      end
    end

    # Cart lines with remove buttons
    def handle_cart_edit(callback)
      draft = Draft.for_user(callback.from.id)
      return edit(callback, "🛒 Корзина пуста") if draft.nil? || draft.empty?

      edit(callback, "✏ Редактирование корзины:\n\nНажмите на товар, чтобы удалить его.",
           reply_markup: Keyboards.cart_edit_keyboard(draft))
    end

    def handle_cart_remove(callback, index)
      draft = Draft.for_user(callback.from.id)
      return unless draft && index < draft.items.length

      removed = draft.items[index]
      draft.remove_item(index)
      name = removed["display_name"] || removed["name"]

      if draft.empty?
        edit(callback, "🗑 Удалено: #{name}\n\nКорзина теперь пуста.")
      else
        edit(callback, "🗑 Удалено: #{name}\n\nПродолжайте редактирование или нажмите 'Назад'.",
             reply_markup: Keyboards.cart_edit_keyboard(draft))
      end
    end

    # Confirmation screen. The cart is re-checked against the menu first, so the client
    # confirms current prices and only available items.
    #
    # @param changes [Hash] result of Draft#sync_with_menu! if the caller already ran it
    def send_confirmation(chat_id, draft, changes = draft.sync_with_menu!)
      if draft.empty?
        send_text(chat_id, "#{menu_changes_text(changes)}🛒 Корзина пуста. /order для нового заказа.")
        return
      end

      text = <<~TEXT
        #{menu_changes_text(changes)}📋 Подтверждение заказа:

        #{draft.format_cart}

        💬 Комментарий: #{draft.comment || '-'}

        Подтвердить заказ?
      TEXT
      send_text(chat_id, text, reply_markup: Keyboards.confirm_keyboard)
    end

    # Note about cart lines changed by Draft#sync_with_menu!, empty if nothing changed
    def menu_changes_text(changes)
      lines = []
      lines << "⚠️ Больше нет в наличии: #{changes[:removed].join(', ')}" if changes[:removed].any?
      lines << "⚠️ Изменилась цена: #{changes[:repriced].join(', ')}" if changes[:repriced].any?
      lines.empty? ? "" : "#{lines.join("\n")}\n\n"
    end

    def handle_confirm(callback, answer)
      user_id = callback.from.id

      if answer == "no"
        Draft.clear(user_id)
        return edit(callback, "❌ Заказ отменён. /order для нового заказа.")
      end

      # A second tap on "✅ Да" after the order was created finds no draft
      draft = Draft.for_user(user_id)
      if draft.nil? || draft.empty?
        return answer_callback(callback, text: "Корзина пуста или заказ уже оформлен. /order для нового заказа.",
                                         show_alert: true)
      end

      # Prices or availability changed since the confirmation screen: confirm again
      changes = draft.sync_with_menu!
      return send_confirmation(user_id, draft, changes) if changes[:removed].any? || changes[:repriced].any?

      place_order(callback, draft)
    end

    def place_order(callback, draft)
      user_id = callback.from.id

      begin
        order = OrderService.create_from_draft(draft, Customer.from_telegram(callback.from))
        unless order
          return send_text(user_id, "❌ Часть позиций больше недоступна. Проверьте корзину и оформите заказ заново.")
        end

        invoice_data = OrderService.create_invoice(order)
      rescue StandardError => e
        # Details go to the log only: provider / internal messages are not for clients.
        # The cart stays, so the client can retry.
        AppLog.error("Failed to create order", user_id: user_id, order_id: order&.id, error: "#{e.class}: #{e.message}")
        return send_text(user_id, INVOICE_FAILED_TEXT)
      end

      Draft.clear(user_id)
      # The invoice exists: a failed edit (e.g. the message is too old) must not
      # stop the payment QR from being sent
      begin
        edit(callback, "✅ Заказ ##{order.id} создан!")
      rescue StandardError => e
        AppLog.warn("Failed to update the confirmation message", order_id: order.id, error: e.message)
      end
      notifier.send_payment_qr(order, invoice_data)
    end

    def handle_skip_comment(callback)
      chat_id = callback.message&.chat&.id || callback.from.id
      draft = Draft.for_user(callback.from.id)
      return answer_callback(callback, text: "Корзина пуста. /order для нового заказа.") unless draft

      draft.set_comment(nil)
      draft.set_step("confirm")
      send_confirmation(chat_id, draft)
    end

    def handle_start_order_callback(callback)
      user_id = callback.from.id
      active = OrderService.active_order_for_client(user_id)
      return answer_callback(callback, text: "У вас уже есть активный заказ ##{active.id}", show_alert: true) if active

      Draft.clear(user_id)
      send_text(user_id, "🏠 Главное меню:", reply_markup: Keyboards.main_menu)
    end

    # === Payment ===

    def handle_check_payment(callback, order_id)
      user_id = callback.from.id
      order = Order.find_by(id: order_id)
      return answer_callback(callback, text: "Заказ не найден") unless order && order.telegram_user_id == user_id

      # No sync once the order is paid: polling / the callback got there first
      result = {}
      unless order.status.in?(PAID_STATUSES)
        begin
          result = OrderService.sync_payment_status(order)
        rescue StandardError => e
          AppLog.error("Failed to check payment status", order_id: order.id, error: "#{e.class}: #{e.message}")
          return answer_callback(callback, text: "⚠️ Не удалось проверить оплату. Попробуйте чуть позже.")
        end
        order.reload

        # Only the caller that changed the order gets the flags (otherwise polling / the
        # callback already announced it), so baristas are told exactly once. The client
        # is answered right here.
        notify_payment_result(order, result, notify_client: false)
      end

      case order.status
      when *PAID_STATUSES
        text = if order.status == OrderStatus::PAID
          "✅ Оплата подтверждена! Заказ ##{order.id} передан в работу."
        else
          "✅ Заказ ##{order.id} оплачен. Статус: #{order.display_status}."
        end
        edit(callback, text)
      when OrderStatus::INVOICE_CREATED
        answer_callback(callback, text: "⏳ Оплата ещё не получена. Попробуйте чуть позже.")
      else
        answer_callback(callback, text: closed_order_text(order, result), show_alert: true)
      end
    end

    # Closed order (expired / cancelled / error). A late payment keeps the order closed
    # and is refunded; a rejected payment (e.g. amount too low) ends in ERROR.
    def closed_order_text(order, result)
      if result[:payment_error]
        payment_problem_text(order)
      elsif result[:refund_required] || order.refund_required?
        "💸 Оплата по заказу ##{order.id} поступила #{late_payment_reason(result[:previous_status] || order.status)}. " \
          "Заказ не будет приготовлен, деньги вернём."
      else
        "Заказ ##{order.id}: #{order.display_status}"
      end
    end

    # Notifications for a payment status change found by a sync started from the bot
    # (check payment button, /cancel). Only the caller that won the transition gets the
    # flags, so the bot has them sent itself: baristas get the new order, the refund
    # request (late payment) or the payment problem alert. Payments::NotifyResultJob
    # ignores results that settled nothing.
    #
    # @param notify_client [Boolean] also send the client the "payment received" message
    #   (false when the client is answered in place; a refund is always announced in full)
    def notify_payment_result(order, result, notify_client:)
      Payments::NotifyResultJob.notify_later(order, result, notify_client: notify_client)
    rescue StandardError => e
      AppLog.error("Failed to queue payment notifications", order_id: order.id, error: "#{e.class}: #{e.message}")
    end

    # Client text for a payment the provider reported but we could not accept
    def payment_problem_text(order)
      "⚠️ Оплата по заказу ##{order.id} не принята: сумма платежа не совпадает с суммой заказа. " \
        "Бариста проверит платёж и свяжется с вами."
    end

    def late_payment_reason(previous_status)
      previous_status == OrderStatus::CANCELLED ? "после отмены заказа" : "после истечения срока счёта"
    end

    # === Barista ===

    def show_barista_panel(update)
      return unless authorize_barista(update)

      text = "🔧 Панель баристы\n\nВыберите действие:"
      if update.is_a?(Telegram::Bot::Types::CallbackQuery)
        edit(update, text, reply_markup: Keyboards.barista_panel_keyboard)
      else
        send_text(update.from.id, text, reply_markup: Keyboards.barista_panel_keyboard)
      end
    end

    def handle_barista_action(callback, action)
      return unless authorize_barista(callback)

      case action
      when "queue" then show_barista_queue(callback)
      when "in_progress" then show_barista_in_progress(callback)
      when "menu" then show_barista_panel(callback)
      end
    end

    def show_barista_queue(callback)
      orders = OrderService.barista_queue
      return edit(callback, "✅ Очередь пуста! Нет ожидающих заказов.") if orders.empty?

      orders.each do |order|
        send_text(callback.from.id, order.format_for_barista, reply_markup: Keyboards.barista_claim_keyboard(order.id))
      end
    end

    def show_barista_in_progress(callback)
      user_id = callback.from.id
      orders = OrderService.barista_in_progress(user_id)
      return edit(callback, "У вас нет заказов в работе.") if orders.empty?

      orders.each do |order|
        send_text(user_id, order.format_for_barista, reply_markup: Keyboards.barista_complete_keyboard(order.id))
      end
    end

    def handle_barista_claim(callback, order_id)
      return unless authorize_barista(callback)

      unless OrderService.claim_order(order_id, callback.from.id)
        return answer_callback(callback, text: "Не удалось принять заказ. Возможно, его уже взял другой бариста.")
      end

      edit(callback, "✅ Заказ ##{order_id} принят в работу!")
      notifier.notify_order_preparing(Order.find(order_id))
    end

    def handle_barista_complete(callback, order_id)
      return unless authorize_barista(callback)

      user_id = callback.from.id
      order = Order.find_by(id: order_id)
      # Only the barista who claimed the order may complete it
      unless order && order.assigned_to_barista_id == user_id
        return answer_callback(callback, text: "Заказ не найден или не принадлежит вам", show_alert: true)
      end
      return unless OrderService.complete_order(order_id, user_id)

      edit(callback, "✅ Заказ ##{order_id} готов!")
      notifier.notify_order_ready(order.reload)
    end

    # A barista confirms that a late payment was returned to the client
    def handle_refund_done(callback, order_id)
      return unless authorize_barista(callback)

      order = Order.find_by(id: order_id)
      unless order&.mark_refunded!(callback.from.id)
        return answer_callback(callback, text: "Возврат уже отмечен или не требуется", show_alert: true)
      end

      edit(callback, "✅ Возврат по заказу ##{order.id} отмечен как выполненный. Клиент уведомлён.")
      notifier.notify_refund_completed(order)
    end

    # === Main menu ===

    def handle_menu_category(callback, key)
      category = MENU_CATEGORIES.fetch(key)
      items = MenuService.items_by_category(category)
      return answer_callback(callback, text: "В категории '#{category}' нет товаров") if items.empty?

      Draft.update_state(callback.from.id, "step" => "select_item", "category" => category)
      edit(callback, "☕ #{category}:\nВыберите товар:", reply_markup: Keyboards.category_keyboard(category, items))
    end

    def handle_menu_popular(callback)
      items = MenuService.popular_items
      return answer_callback(callback, text: "Нет популярных товаров") if items.empty?

      lines = items.each_with_index.map { |item, idx| "#{idx + 1}. #{item.name} — #{item.formatted_price}" }
      edit(callback, "🔥 Популярные товары:\n\n#{lines.join("\n")}\n", reply_markup: Keyboards.popular_keyboard(items))
    end

    def handle_menu_cart(callback)
      draft = Draft.for_user(callback.from.id)
      return edit(callback, "🛒 Корзина пуста\n\nДобавьте товары из меню.") if draft.nil? || draft.empty?

      edit(callback, "🛒 Ваша корзина:\n\n#{draft.format_cart}", reply_markup: Keyboards.cart_keyboard)
    end

    def handle_menu_orders(callback)
      orders = OrderService.client_orders(callback.from.id, limit: 5)
      return answer_callback(callback, text: "У вас пока нет заказов") if orders.empty?

      text = +"📦 Ваши последние заказы:\n\n"
      orders.each do |order|
        text << "##{order.id} — #{order.display_status} — #{order.formatted_total}\n"
        text << "   📅 #{local_time(order.created_at)}\n\n"
      end
      edit(callback, text)
    end

    def handle_menu_main(callback)
      edit(callback, "🏠 Главное меню:", reply_markup: Keyboards.main_menu)
    end

    def handle_addon_toggle(callback, item_id, addon_id)
      user_id = callback.from.id
      draft = Draft.for_user(user_id)
      return answer_callback(callback, text: "Начните заказ сначала") unless draft

      selected = Array(draft.state["selected_addons"])
      selected.include?(addon_id) ? selected.delete(addon_id) : selected << addon_id
      draft.update_state("selected_addons" => selected)

      api.edit_message_reply_markup(chat_id: user_id, message_id: callback.message&.message_id,
                                    reply_markup: Keyboards.addons_keyboard(item_id, selected))
    end

    def handle_addons_done(callback, item_id)
      draft = Draft.for_user(callback.from.id)
      return answer_callback(callback, text: "Начните заказ сначала") unless draft

      draft.update_state("addons_for_item" => { item_id.to_s => Array(draft.state["selected_addons"]) })
      edit(callback, "🔢 Выберите количество:", reply_markup: Keyboards.quantity_keyboard(item_id))
    end

    def handle_add_item(callback, item_id)
      user_id = callback.from.id
      item = available_item(item_id)
      return answer_callback(callback, text: ITEM_NOT_FOUND) unless item

      Draft.update_state(user_id, "step" => "select_item", "current_item_id" => item_id)
      return show_size_menu(callback, item) if item.has_sizes?

      edit(callback, "#{item.name} — #{item.formatted_price}\n\n🔢 Выберите количество:",
           reply_markup: Keyboards.quantity_keyboard(item_id))
    end

    # New cart from a previous order: same sizes and quantities, current prices, only
    # items that are still available
    def handle_quick_reorder(callback, order_id)
      user_id = callback.from.id
      order = Order.find_by(id: order_id)
      return answer_callback(callback, text: "Заказ не найден") unless order && order.telegram_user_id == user_id

      Draft.clear(user_id)
      draft = Draft.get_or_create(user_id)
      unavailable = []
      order.order_items.each do |order_item|
        menu_item = MenuItem.find_by(id: order_item.menu_item_id)
        if menu_item&.available?
          draft.add_item_with_size(menu_item, order_item.size, order_item.qty)
        else
          unavailable << order_item.item_name
        end
      end

      note = unavailable.any? ? "\n\n⚠️ Больше нет в наличии: #{unavailable.join(', ')}" : ""
      if draft.empty?
        return edit(callback, "😔 Не удалось повторить заказ ##{order.id}: позиций больше нет в меню.#{note}")
      end

      edit(callback, "🔄 Заказ повторён!\n\n#{draft.format_cart}#{note}", reply_markup: Keyboards.cart_keyboard)
    end

    def handle_upsell(callback, action, item_id)
      if action == "add" && item_id
        draft = Draft.for_user(callback.from.id)
        item = available_item(item_id)
        draft.add_item(item, 1) if draft && item
      end

      handle_cart_action(callback, "checkout")
    end

    # === Sizes ===

    def handle_size_menu(callback, item_id)
      item = available_item(item_id)
      return answer_callback(callback, text: ITEM_NOT_FOUND) unless item
      # Item without sizes: straight to the quantity
      return handle_item_select(callback, item_id) unless item.has_sizes?

      show_size_menu(callback, item)
    end

    def show_size_menu(callback, item)
      edit(callback, "☕ #{item.name}\n\n#{item.formatted_prices}\n\nВыберите размер:", reply_markup: Keyboards.size_keyboard(item))
    end

    def handle_size_select(callback, item_id, size)
      item = available_item(item_id)
      return answer_callback(callback, text: ITEM_NOT_FOUND) unless item

      Draft.update_state(callback.from.id, "current_item_id" => item_id, "current_size" => size)
      edit(callback, "☕ #{item.name} (#{MenuItem::SIZE_LABELS[size]}) — #{item.formatted_price_for_size(size)}\n\n" \
                     "Выберите количество:", reply_markup: Keyboards.quantity_keyboard(item_id, size))
    end

    def handle_qty_with_size(callback, item_id, size, qty)
      item = available_item(item_id)
      return answer_callback(callback, text: ITEM_NOT_FOUND) unless item

      # Crafted callbacks may carry any quantity: 0 is rejected, the line is capped
      draft = Draft.get_or_create(callback.from.id)
      return answer_callback(callback, text: INVALID_QTY_TEXT, show_alert: true) unless draft.add_item_with_size(item, size, qty)

      added_qty = [ qty, Draft::MAX_QTY_PER_LINE ].min
      edit(callback, "✅ Добавлено: #{item.display_name_for_size(size)} x#{added_qty}\n\n#{draft.format_cart}",
           reply_markup: Keyboards.cart_keyboard)
    end

    # === Helpers ===

    # Menu item that can be put into the cart (stale buttons may point to removed or
    # switched-off items)
    def available_item(id)
      item = MenuService.find_item(id)
      item if item&.available?
    end

    def send_text(chat_id, text, reply_markup: nil)
      params = { chat_id: chat_id, text: text }
      params[:reply_markup] = reply_markup if reply_markup
      api.send_message(**params)
    end

    # Replace the message the button belongs to (a new message if Telegram did not send it)
    def edit(callback, text, reply_markup: nil)
      message_id = callback.message&.message_id
      return send_text(callback.from.id, text, reply_markup: reply_markup) unless message_id

      params = { chat_id: callback.from.id, message_id: message_id, text: text }
      params[:reply_markup] = reply_markup if reply_markup
      api.edit_message_text(**params)
    rescue Telegram::Bot::Exceptions::ResponseError => e
      # A repeated tap on the same button: the message already shows this
      raise unless e.message.include?("message is not modified")
    end

    # Answer a callback query at most once (Telegram rejects a second answer, so a
    # toast/alert sent after an earlier answer would never reach the user)
    #
    # @return [Boolean] true if an answer was sent
    def answer_callback(callback, text: nil, show_alert: false)
      return false if @answered_callback_id == callback.id

      @answered_callback_id = callback.id
      params = { callback_query_id: callback.id }
      params[:text] = text if text
      params[:show_alert] = true if show_alert
      api.answer_callback_query(**params)
      true
    rescue StandardError => e
      # Best effort (e.g. the query is too old). Never raises: also called from an ensure.
      AppLog.error("Failed to answer callback query", callback_id: callback.id, error: e.message)
      false
    end

    # Barista-only actions are allowed to the active staff of this coffee shop only
    #
    # @return [Boolean] true if the sender is a barista
    def authorize_barista(update)
      user_id = update.from.id
      return true if AuthService.barista?(user_id)

      if update.is_a?(Telegram::Bot::Types::CallbackQuery)
        AppLog.info("Unauthorized barista action", user_id: user_id, data: update.data.to_s[0, 64])
        answer_callback(update, text: BARISTA_ACCESS_DENIED, show_alert: true)
      else
        AppLog.info("Unauthorized barista action", user_id: user_id, text: update.text.to_s[0, 50])
        send_text(user_id, BARISTA_ACCESS_DENIED)
      end
      false
    end

    # "28.09 14:05" in the coffee shop's time zone
    def local_time(time) = time.in_time_zone(tenant&.time_zone || Time.zone).strftime("%d.%m %H:%M")
  end
end
