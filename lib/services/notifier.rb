# frozen_string_literal: true

# Notifier Service
# Handles Telegram notifications to clients and baristas

require_relative '../../config/boot'
require 'telegram/bot'

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
          ✅ Ваш заказ ##{order.id} принят!
          
          💰 Сумма: #{order.formatted_total}
          
          Ожидайте счёт для оплаты.
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
          
          💰 Сумма: #{order.formatted_total}
          
          Отсканируйте QR-код выше или перейдите по ссылке для оплаты.
          
          ⏰ Ссылка действительна #{CoffeeBot::Config::ORDER_EXPIRE_MINUTES} минут.
        TEXT

        # Send text with payment link
        if payment_url
          keyboard = Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [
              [Telegram::Bot::Types::InlineKeyboardButton.new(
                text: '💳 Оплатить',
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
          ✅ Оплата получена!
          
          Заказ ##{order.id} передан в работу.
          Мы уведомим вас, когда заказ будет готов.
        TEXT

        send_to_client(order.telegram_user_id, text)
        update_last_notified(order, OrderStatus::PAID)
      end

      # Notify client that order is being prepared
      #
      # @param order [Order] The order
      def notify_order_preparing(order)
        text = <<~TEXT
          ☕ С любовью готовим ваш заказ ##{order.id}!
          
          Скоро будет готов 🧡
        TEXT

        send_to_client(order.telegram_user_id, text)
        update_last_notified(order, OrderStatus::IN_PROGRESS)
      end

      # Notify client that order is ready
      #
      # @param order [Order] The order
      def notify_order_ready(order)
        text = <<~TEXT
          ✅ Ваш заказ ##{order.id} готов!
          
          Забирайте на барной стойке 🧡
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
          ❌ Заказ ##{order.id} отменён.
          
          #{reason if reason}
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Notify client about expired invoice
      #
      # @param order [Order] The order
      def notify_invoice_expired(order)
        text = <<~TEXT
          ⏰ Время оплаты заказа ##{order.id} истекло.
          
          Оформите заказ заново.
        TEXT

        send_to_client(order.telegram_user_id, text)
      end

      # Notify baristas about new order
      #
      # @param order [Order] The order
      def notify_baristas_new_order(order)
        text = <<~TEXT
          🔔 Новый оплаченный заказ!
          
          #{order.format_for_barista}
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

      # Notify baristas about order status change
      #
      # @param order [Order] The order
      # @param status [String] New status
      def notify_baristas_order_status(order, status)
        text = case status
        when OrderStatus::READY
          "✅ Заказ ##{order.id} выдан клиенту"
        when OrderStatus::CANCELLED
          "❌ Заказ ##{order.id} отменён"
        else
          "📋 Заказ ##{order.id}: #{OrderStatus.display_name(status)}"
        end

        send_to_baristas(text)
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
      end

      # Send QR code as image from URL
      def send_qr_image_from_url(chat_id, url)
        require 'tempfile'
        require 'open-uri'

        # Download image from URL
        image_data = URI.open(url).read

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
      rescue StandardError => e
        log_error('Failed to send QR image from URL', chat_id: chat_id, url: url, error: e.message)
      end

      # Send QR code as image (base64)
      def send_qr_image(chat_id, base64_data)
        require 'tempfile'
        require 'base64'

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
      rescue StandardError => e
        log_error('Failed to send QR image', chat_id: chat_id, error: e.message)
      end

      # Update last notified status
      def update_last_notified(order, status)
        order.update(last_notified_status: status)
      end
    end
  end
end
