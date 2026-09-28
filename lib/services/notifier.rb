# frozen_string_literal: true

# Notifier Service
# Handles Telegram notifications to clients and baristas

require_relative '../../config/boot'
require 'telegram/bot'
require 'tempfile'
require 'base64'
require 'bigdecimal'
require 'open-uri'

module CoffeeBot
  module Services
    class Notifier
      attr_reader :bot

      def initialize(bot)
        @bot = bot
      end

      # Send message to client
      #
      # @param telegram_user_id [Integer] Client's Telegram ID
      # @param text [String] Message text
      # @param options [Hash] Additional options (parse_mode, reply_markup, etc.)
      # @return [Boolean] True if sent successfully
      def send_to_client(telegram_user_id, text, **options)
        send_message(telegram_user_id, text, **options)
      end

      # Send message to all baristas
      #
      # @param text [String] Message text
      # @param options [Hash] Additional options
      # @return [Integer] Number of messages sent
      def send_to_baristas(text, **options)
        count = 0
        AuthService.all_baristas.each do |barista_id|
          if send_message(barista_id, text, **options)
            count += 1
          end
        end
        count
      end

      # Notify client about new order
      #
      # @param order [Order] The order
      def notify_order_created(order)
        text = <<~TEXT
          ✅ Заказ ##{order.id} оформлен!
          
          📋 Позиций: #{order.items.count}
          💰 Сумма: #{order.formatted_total}
          
          📱 Ожидайте счёт для оплаты
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Send payment link to client
      #
      # @param order [Order] The order
      # @param invoice_data [Hash] Invoice data with payment link
      def send_payment_qr(order, invoice_data)
        # Use paylink_url (mwallet) or qr_url (legacy)
        payment_url = invoice_data[:paylink_url] || invoice_data[:qr_url]
        emv_qr_url = invoice_data[:emv_qr_url]

        # First, send QR code image if URL is available
        if emv_qr_url
          send_qr_image_from_url(order.telegram_user_id, emv_qr_url)
        end

        # Then send text with payment link button
        text = <<~TEXT
          💳 Оплата заказа ##{order.id}
          
          💰 К оплате: #{order.formatted_total}
          
          📱 Отсканируйте QR-код или нажмите кнопку ниже
          
          ⏰ Оплатить в течение #{CoffeeBot::Config::ORDER_EXPIRE_MINUTES} минут
        TEXT

        # Send text with payment link
        if payment_url
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '💳 Оплатить онлайн',
                url: payment_url
              )],
              [Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '🔄 Проверить оплату',
                callback_data: "check_payment_#{order.id}"
              )]
            ]
          )

          send_to_client(order.telegram_user_id, text, reply_markup: keyboard)
        else
          send_to_client(order.telegram_user_id, text)
        end
      end

      # Notify client about payment received
      #
      # @param order [Order] The order
      def notify_payment_received(order)
        text = <<~TEXT
          ✅ Оплата прошла успешно!

          📋 Заказ ##{order.id} передан в работу
          ☕ Бариста уже начинает готовить

          🔔 Мы напишем, когда всё будет готово
        TEXT

        send_to_client(order.telegram_user_id, text)
        update_last_notified(order, OrderStatus::PAID)
      end

      # Tell the client that a late payment will be returned
      # (paid after the invoice expired / the order was cancelled; the order is not made)
      #
      # @param order [Order] The order (EXPIRED or CANCELLED)
      # @param previous_status [String, nil] Order status at the time of payment
      def notify_refund_pending(order, previous_status: nil)
        text = <<~TEXT
          💸 Оплата по заказу ##{order.id} поступила #{late_payment_reason(previous_status || order.status)}

          Заказ не будет приготовлен, деньги вернём.
          Если есть вопросы, обратитесь к баристе.

          🔄 Новый заказ можно оформить через меню
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Tell the client that the late payment has been returned
      #
      # @param order [Order] The order
      def notify_refund_completed(order)
        send_to_client(order.telegram_user_id, "💸 Деньги за заказ ##{order.id} возвращены.")
      end

      # Send all notifications for a payment status change
      # Call only with the result of the caller that won the status transition
      # (MWallet::Service#sync_status / #process_callback), so each goes out once.
      #
      # @param order [Order] The order
      # @param result [Hash] :notify_barista, :refund_required, :previous_status,
      #   :payment_error, :expected_amount, :paid_amount
      def notify_payment_result(order, result)
        if result[:payment_error]
          notify_baristas_payment_problem(order,
            expected_amount: result[:expected_amount],
            paid_amount: result[:paid_amount]
          )
        elsif result[:refund_required]
          # Staff first: they make the refund; the client message must not block it
          deliver_safely(order, 'baristas_refund_required') do
            notify_baristas_refund_required(order,
              paid_amount: result[:paid_amount],
              previous_status: result[:previous_status]
            )
          end
          deliver_safely(order, 'client_refund_pending') do
            notify_refund_pending(order, previous_status: result[:previous_status])
          end
        elsif result[:notify_barista]
          # Nobody else will send these (winner-only), so baristas go first and each
          # message is isolated: a failed client message must not cost baristas the order
          deliver_safely(order, 'baristas_new_order') { notify_baristas_new_order(order) }
          deliver_safely(order, 'client_payment_received') { notify_payment_received(order) }
        end
      end

      # Notify client that order is being prepared
      #
      # @param order [Order] The order
      def notify_order_preparing(order)
        text = <<~TEXT
          ☕ Готовим ваш заказ ##{order.id}!
          
          ⏱ Ориентировочное время: 5-10 минут
          
          🔔 Скоро напишем, когда можно будет забрать
        TEXT

        send_to_client(order.telegram_user_id, text)
        update_last_notified(order, OrderStatus::IN_PROGRESS)
      end

      # Notify client that order is ready
      #
      # @param order [Order] The order
      def notify_order_ready(order)
        text = <<~TEXT
          ✅ Заказ ##{order.id} готов!
          
          📍 Забирайте на барной стойке
          
          🧡 Приятного кофепития!
        TEXT

        send_to_client(order.telegram_user_id, text)
        update_last_notified(order, OrderStatus::READY)
      end

      # Notify client about order cancellation
      #
      # @param order [Order] The order
      # @param reason [String] Cancellation reason
      def notify_order_cancelled(order, reason = nil)
        text = <<~TEXT
          ❌ Заказ ##{order.id} отменён
          
          #{reason if reason}
          
          🔄 Оформите заказ заново через меню
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Notify client about expired invoice
      #
      # @param order [Order] The order
      def notify_invoice_expired(order)
        text = <<~TEXT
          ⏰ Время оплаты истекло
          
          Заказ ##{order.id} отменён
          
          🔄 Оформите заказ заново через меню
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Notify baristas about new order
      #
      # @param order [Order] The order
      def notify_baristas_new_order(order)
        wait_time = ((Time.now.utc - order.created_at) / 60).round
        wait_indicator = wait_time > 10 ? '🔴' : (wait_time > 5 ? '⚠️' : '🟢')

        text = <<~TEXT
          🔔 Новый заказ ##{order.id}!

          #{order.format_for_barista}

          ⏱ В очереди: #{wait_time} мин #{wait_indicator}
        TEXT

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '✅ Принять в работу',
              callback_data: "barista_claim_#{order.id}"
            )]
          ]
        )

        send_to_baristas(text, reply_markup: keyboard)
      end

      # Alert baristas that a payment could not be accepted (e.g. paid less than the total)
      #
      # @param order [Order] The order (already in ERROR status)
      # @param expected_amount [Integer, nil] Order total in tyiyn
      # @param paid_amount [Numeric, nil] Amount reported by the provider in tyiyn
      def notify_baristas_payment_problem(order, expected_amount: nil, paid_amount: nil)
        paid_text = paid_amount ? format_tyiyn(paid_amount) : 'не удалось определить'

        text = <<~TEXT
          ⚠️ Проблема с оплатой заказа ##{order.id}

          👤 #{order.client_display_name}
          💰 Сумма заказа: #{format_tyiyn(expected_amount || order.total_amount)}
          💳 Оплачено: #{paid_text}

          Заказ не передан в работу (статус «#{OrderStatus.display_name(OrderStatus::ERROR)}»).
          Проверьте платёж в кабинете MWallet и свяжитесь с клиентом.
        TEXT

        send_to_baristas(text)
      end

      # Ask baristas to return a late payment (the order is not made)
      # The button closes the refund (Router: refund_done_<order_id>).
      #
      # @param order [Order] The order (EXPIRED or CANCELLED)
      # @param paid_amount [Integer, nil] Amount paid in tyiyn
      # @param previous_status [String, nil] Order status at the time of payment
      def notify_baristas_refund_required(order, paid_amount: nil, previous_status: nil)
        text = <<~TEXT
          💸 Требуется возврат по заказу ##{order.id}

          Клиент оплатил #{late_payment_reason(previous_status || order.status)}, заказ готовить не нужно.

          👤 #{order.client_display_name} (Telegram ID #{order.telegram_user_id})
          💳 Оплачено: #{format_tyiyn(paid_amount || order.total_amount)}
          🧾 Счёт MWallet: #{order.invoice_id_provider}

          Верните деньги через кабинет MWallet и нажмите кнопку ниже.
        TEXT

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [Telegram::Bot::Types::InlineKeyboardButton.new(
              text: '✅ Возврат выполнен',
              callback_data: "refund_done_#{order.id}"
            )]
          ]
        )

        send_to_baristas(text, reply_markup: keyboard)
      end

      # Notify baristas about order status change
      #
      # @param order [Order] The order
      # @param status [String] New status
      def notify_baristas_order_status(order, status)
        text = case status
        when OrderStatus::READY
          "✅ Заказ ##{order.id} готов и выдан клиенту"
        when OrderStatus::CANCELLED
          "❌ Заказ ##{order.id} отменён"
        else
          "📋 Заказ ##{order.id}: #{OrderStatus.display_name(status)}"
        end

        send_to_baristas(text)
      end
      
      # Suggest upsell to client after ordering coffee
      #
      # @param telegram_user_id [Integer] Client's Telegram ID
      # @param dessert_item [MenuItem] Dessert item to suggest
      def suggest_upsell(telegram_user_id, dessert_item)
        text = <<~TEXT
          🍰 Добавить десерт к заказу?
          
          #{dessert_item.name} — #{dessert_item.formatted_price}
          
          Отлично сочетается с кофе! ☕
        TEXT

        keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
          inline_keyboard: [
            [
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '➕ Добавить',
                callback_data: "upsell_add_#{dessert_item.id}"
              ),
              Telegram::Bot::Types::InlineKeyboardButton.new(
                text: 'Нет, спасибо',
                callback_data: 'upsell_skip'
              )
            ]
          ]
        )

        send_to_client(telegram_user_id, text, reply_markup: keyboard)
      end

      private

      # Send message via Telegram API
      def send_message(chat_id, text, **options)
        bot.api.send_message(
          chat_id: chat_id,
          text: text,
          **options
        )
        true
      rescue Telegram::Bot::Exceptions::ResponseError => e
        log_error('Failed to send message', chat_id: chat_id, error: e.message)
        false
      rescue Faraday::Error => e
        # telegram-bot-ruby does not wrap connection errors / timeouts
        log_error('Failed to send message: Telegram unreachable', chat_id: chat_id, error: e.class.name)
        false
      end

      # Run one notification; any error is logged instead of propagated,
      # so the notifications that follow are still sent
      #
      # @return [Object, false] Block result, false on error
      def deliver_safely(order, notification)
        yield
      rescue StandardError => e
        log_error('Failed to send payment notification',
          order_id: order.id,
          notification: notification,
          error: "#{e.class}: #{e.message}"
        )
        false
      end

      # Send QR code as image from URL
      # @param chat_id [Integer] Telegram chat ID
      # @param url [String] URL to QR code image
      # @return [Boolean] True if sent successfully
      def send_qr_image_from_url(chat_id, url)
        # Download image from URL with timeout
        image_data = URI.open(url, open_timeout: 5, read_timeout: 10).read

        # Write to temp file
        Tempfile.create(['qr', '.png']) do |file|
          file.binmode
          file.write(image_data)
          file.rewind

          # Send photo
          bot.api.send_photo(
            chat_id: chat_id,
            photo: Faraday::UploadIO.new(file.path, 'image/png'),
            caption: "QR-код для оплаты"
          )
        end
        true
      rescue OpenURI::HTTPError => e
        log_error('Failed to fetch QR image', chat_id: chat_id, url: url, error: e.message)
        false
      rescue StandardError => e
        log_error('Failed to send QR image from URL', chat_id: chat_id, url: url, error: e.message)
        false
      end

      # Send QR code as image (base64)
      # @param chat_id [Integer] Telegram chat ID
      # @param base64_data [String] Base64 encoded image data
      # @return [Boolean] True if sent successfully
      def send_qr_image(chat_id, base64_data)
        # Decode base64 image
        image_data = Base64.decode64(base64_data)

        # Write to temp file
        Tempfile.create(['qr', '.png']) do |file|
          file.binmode
          file.write(image_data)
          file.rewind

          # Send photo
          bot.api.send_photo(
            chat_id: chat_id,
            photo: Faraday::UploadIO.new(file.path, 'image/png')
          )
        end
        true
      rescue StandardError => e
        log_error('Failed to send QR image', chat_id: chat_id, error: e.message)
        false
      end

      # Update last notified status
      def update_last_notified(order, status)
        order.update(last_notified_status: status)
      end

      # "после истечения срока счёта" / "после отмены заказа"
      def late_payment_reason(previous_status)
        previous_status == OrderStatus::CANCELLED ? 'после отмены заказа' : 'после истечения срока счёта'
      end

      # Amount in tyiyn -> "150.00 KGS"
      def format_tyiyn(amount)
        format('%.2f KGS', BigDecimal(amount.to_s) / 100)
      end
    end
  end
end
