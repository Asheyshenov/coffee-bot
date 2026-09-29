# frozen_string_literal: true

require "bigdecimal"
require "base64"
require "stringio"

# Telegram notifications of one coffee shop to its customers and staff,
# sent through the shop's own bot. Staff = active StaffMembers of the bot's tenant.
#
#   Notifier.for(tenant).notify_payment_result(order, result)
class Notifier
  QR_DOWNLOAD_OPEN_TIMEOUT = 5
  QR_DOWNLOAD_READ_TIMEOUT = 10

  attr_reader :bot

  # @param tenant [Tenant]
  # @return [Notifier] for the tenant's active bot (messages fail softly without one)
  def self.for(tenant)
    new(tenant.bot, tenant: tenant)
  end

  # @param bot [Bot, nil] Bot record (bot.api is the Telegram API client)
  # @param tenant [Tenant, nil] defaults to the bot's tenant, then the current tenant
  def initialize(bot, tenant: nil)
    @bot = bot
    @tenant = tenant
  end

  def tenant
    @tenant ||= bot&.tenant || ActsAsTenant.current_tenant
  end

  # @return [Boolean] true if sent
  def send_to_client(telegram_user_id, text, **options)
    send_message(telegram_user_id, text, **options)
  end

  # @return [Integer] number of staff members the message was delivered to
  def send_to_baristas(text, **options)
    staff_chat_ids.count { |chat_id| send_message(chat_id, text, **options) }
  end

  # Telegram IDs of the active staff of this coffee shop
  def staff_chat_ids
    return [] unless tenant

    ActsAsTenant.with_tenant(tenant) { StaffMember.active.order(:id).pluck(:telegram_user_id) }
  end

  def notify_order_created(order)
    text = <<~TEXT
      ✅ Заказ ##{order.id} оформлен!

      📋 Позиций: #{order.order_items.size}
      💰 Сумма: #{order.formatted_total}

      📱 Ожидайте счёт для оплаты
    TEXT

    send_to_client(order.telegram_user_id, text)
  end

  # QR image (if the provider gave one) and the payment link
  #
  # @param invoice_data [Hash] result of MWallet::Service#create_invoice_for_order
  def send_payment_qr(order, invoice_data)
    payment_url = invoice_data[:paylink_url] || invoice_data[:qr_url]

    if invoice_data[:emv_qr_url].present?
      send_qr_image_from_url(order.telegram_user_id, invoice_data[:emv_qr_url])
    elsif invoice_data[:qr_image_base64].present?
      send_qr_image(order.telegram_user_id, invoice_data[:qr_image_base64])
    end

    text = <<~TEXT
      💳 Оплата заказа ##{order.id}

      💰 К оплате: #{order.formatted_total}

      📱 Отсканируйте QR-код или нажмите кнопку ниже

      ⏰ Оплатить в течение #{expire_minutes(order)} минут
    TEXT

    return send_to_client(order.telegram_user_id, text) unless payment_url

    keyboard = inline_keyboard(
      [ url_button("💳 Оплатить онлайн", payment_url) ],
      [ callback_button("🔄 Проверить оплату", "check_payment_#{order.id}") ]
    )
    send_to_client(order.telegram_user_id, text, reply_markup: keyboard)
  end

  def notify_payment_received(order)
    text = <<~TEXT
      ✅ Оплата прошла успешно!

      📋 Заказ ##{order.id} передан в работу
      ☕ Бариста уже начинает готовить

      🔔 Мы напишем, когда всё будет готово
    TEXT

    sent = send_to_client(order.telegram_user_id, text)
    update_last_notified(order, OrderStatus::PAID)
    sent
  end

  # A late payment (after the invoice expired / the order was cancelled) will be returned
  #
  # @param previous_status [String, nil] order status at the time of payment
  def notify_refund_pending(order, previous_status: nil)
    text = <<~TEXT
      💸 Оплата по заказу ##{order.id} поступила #{late_payment_reason(previous_status || order.status)}

      Заказ не будет приготовлен, деньги вернём.
      Если есть вопросы, обратитесь к баристе.

      🔄 Новый заказ можно оформить через меню
    TEXT

    send_to_client(order.telegram_user_id, text)
  end

  def notify_refund_completed(order)
    send_to_client(order.telegram_user_id, "💸 Деньги за заказ ##{order.id} возвращены.")
  end

  # All notifications for a payment status change. Call only with the result of the
  # caller that won the status transition (MWallet::Service#sync_status /
  # #process_callback), so each message goes out once.
  #
  # @param result [Hash] :notify_barista, :refund_required, :previous_status,
  #   :payment_error, :expected_amount, :paid_amount
  # @param notify_client [Boolean] false when the caller answers the client itself
  #   (e.g. the "check payment" button): only staff are told. A refund is always
  #   announced in full, the client keeps a message about their money.
  def notify_payment_result(order, result, notify_client: true)
    result = result.to_h.symbolize_keys

    if !notify_client && !result[:refund_required]
      notify_staff_only(order, result)
    elsif result[:payment_error]
      deliver_safely(order, "baristas_payment_problem") do
        notify_baristas_payment_problem(order, expected_amount: result[:expected_amount], paid_amount: result[:paid_amount])
      end
    elsif result[:refund_required]
      # Staff first: they make the refund; the client message must not block it
      deliver_safely(order, "baristas_refund_required") do
        notify_baristas_refund_required(order, paid_amount: result[:paid_amount], previous_status: result[:previous_status])
      end
      deliver_safely(order, "client_refund_pending") do
        notify_refund_pending(order, previous_status: result[:previous_status])
      end
    elsif result[:notify_barista]
      # Nobody else sends these (winner-only), so baristas go first and each message is
      # isolated: a failed client message must not cost the baristas the order
      deliver_safely(order, "baristas_new_order") { notify_baristas_new_order(order) }
      deliver_safely(order, "client_payment_received") { notify_payment_received(order) }
    end
  end

  def notify_order_preparing(order)
    text = <<~TEXT
      ☕ Готовим ваш заказ ##{order.id}!

      ⏱ Ориентировочное время: 5-10 минут

      🔔 Скоро напишем, когда можно будет забрать
    TEXT

    sent = send_to_client(order.telegram_user_id, text)
    update_last_notified(order, OrderStatus::IN_PROGRESS)
    sent
  end

  def notify_order_ready(order)
    text = <<~TEXT
      ✅ Заказ ##{order.id} готов!

      📍 Забирайте на барной стойке

      🧡 Приятного кофепития!
    TEXT

    sent = send_to_client(order.telegram_user_id, text)
    update_last_notified(order, OrderStatus::READY)
    sent
  end

  def notify_order_cancelled(order, reason = nil)
    lines = [ "❌ Заказ ##{order.id} отменён", "" ]
    lines += [ reason, "" ] if reason.present?
    lines << "🔄 Оформите заказ заново через меню"

    send_to_client(order.telegram_user_id, lines.join("\n"))
  end

  # @return [Boolean] true if the client got the message
  def notify_invoice_expired(order)
    text = <<~TEXT
      ⏰ Время оплаты истекло

      Заказ ##{order.id} отменён

      🔄 Оформите заказ заново через меню
    TEXT

    send_to_client(order.telegram_user_id, text)
  end

  def notify_baristas_new_order(order)
    wait_time = ((Time.current - order.created_at) / 60).round
    wait_indicator = if wait_time > 10 then "🔴"
    elsif wait_time > 5 then "⚠️"
    else "🟢"
    end

    text = <<~TEXT
      🔔 Новый заказ ##{order.id}!

      #{order.format_for_barista}

      ⏱ В очереди: #{wait_time} мин #{wait_indicator}
    TEXT

    keyboard = inline_keyboard([ callback_button("✅ Принять в работу", "barista_claim_#{order.id}") ])
    send_to_baristas(text, reply_markup: keyboard)
  end

  # A payment could not be accepted (e.g. paid less than the total); the order is ERROR
  #
  # @param expected_amount [Integer, nil] order total in tyiyn
  # @param paid_amount [Numeric, String, nil] amount reported by the provider in tyiyn
  def notify_baristas_payment_problem(order, expected_amount: nil, paid_amount: nil)
    paid_text = paid_amount.present? ? format_tyiyn(paid_amount) : "не удалось определить"

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

  # Ask staff to return a late payment; the button closes the refund (refund_done_<order_id>)
  #
  # @param paid_amount [Integer, nil] amount paid in tyiyn
  # @param previous_status [String, nil] order status at the time of payment
  def notify_baristas_refund_required(order, paid_amount: nil, previous_status: nil)
    text = <<~TEXT
      💸 Требуется возврат по заказу ##{order.id}

      Клиент оплатил #{late_payment_reason(previous_status || order.status)}, заказ готовить не нужно.

      👤 #{order.client_display_name} (Telegram ID #{order.telegram_user_id})
      💳 Оплачено: #{format_tyiyn(paid_amount.presence || order.total_amount)}
      🧾 Счёт MWallet: #{order.invoice_id_provider}

      Верните деньги через кабинет MWallet и нажмите кнопку ниже.
    TEXT

    keyboard = inline_keyboard([ callback_button("✅ Возврат выполнен", "refund_done_#{order.id}") ])
    send_to_baristas(text, reply_markup: keyboard)
  end

  def notify_baristas_order_status(order, status)
    text = case status
    when OrderStatus::READY then "✅ Заказ ##{order.id} готов и выдан клиенту"
    when OrderStatus::CANCELLED then "❌ Заказ ##{order.id} отменён"
    else "📋 Заказ ##{order.id}: #{OrderStatus.display_name(status)}"
    end

    send_to_baristas(text)
  end

  # @param dessert_item [MenuItem]
  def suggest_upsell(telegram_user_id, dessert_item)
    text = <<~TEXT
      🍰 Добавить десерт к заказу?

      #{dessert_item.name} — #{dessert_item.formatted_price}

      Отлично сочетается с кофе! ☕
    TEXT

    keyboard = inline_keyboard(
      [ callback_button("➕ Добавить", "upsell_add_#{dessert_item.id}"), callback_button("Нет, спасибо", "upsell_skip") ]
    )
    send_to_client(telegram_user_id, text, reply_markup: keyboard)
  end

  private

  def notify_staff_only(order, result)
    if result[:payment_error]
      deliver_safely(order, "baristas_payment_problem") do
        notify_baristas_payment_problem(order, expected_amount: result[:expected_amount], paid_amount: result[:paid_amount])
      end
    elsif result[:notify_barista]
      deliver_safely(order, "baristas_new_order") { notify_baristas_new_order(order) }
      deliver_safely(order, "last_notified_status") { update_last_notified(order, OrderStatus::PAID) }
    end
  end

  def send_message(chat_id, text, **options)
    unless bot
      AppLog.error("Failed to send message: coffee shop has no active bot", chat_id: chat_id)
      return false
    end

    bot.api.send_message(chat_id: chat_id, text: text, **options)
    true
  rescue Telegram::Bot::Exceptions::ResponseError => e
    AppLog.error("Failed to send message", chat_id: chat_id, error: e.message)
    false
  rescue Faraday::Error => e
    # telegram-bot-ruby does not wrap connection errors / timeouts
    AppLog.error("Failed to send message: Telegram unreachable", chat_id: chat_id, error: e.class.name)
    false
  end

  # Run one notification; an error is logged instead of propagated, so the
  # notifications that follow are still sent
  #
  # @return [Object, false] block result, false on error
  def deliver_safely(order, notification)
    yield
  rescue StandardError => e
    AppLog.error("Failed to send payment notification", order_id: order.id, notification: notification,
                                                          error: "#{e.class}: #{e.message}")
    false
  end

  # Download the QR image (bounded timeouts) and upload it to Telegram
  def send_qr_image_from_url(chat_id, url)
    response = Faraday.new do |f|
      f.options.open_timeout = QR_DOWNLOAD_OPEN_TIMEOUT
      f.options.timeout = QR_DOWNLOAD_READ_TIMEOUT
    end.get(url)
    raise "HTTP #{response.status}" unless response.success?

    send_photo(chat_id, response.body, caption: "QR-код для оплаты")
  rescue StandardError => e
    AppLog.error("Failed to send QR image from URL", chat_id: chat_id, error: "#{e.class}: #{e.message}")
    false
  end

  # @param base64_data [String] image, optionally as a data URI
  def send_qr_image(chat_id, base64_data)
    image = Base64.decode64(base64_data.to_s.sub(/\Adata:[^,]*,/, ""))
    send_photo(chat_id, image, caption: "QR-код для оплаты")
  rescue StandardError => e
    AppLog.error("Failed to send QR image", chat_id: chat_id, error: "#{e.class}: #{e.message}")
    false
  end

  def send_photo(chat_id, image_data, caption:)
    # Image bytes: String#present? would run a regexp and fail on non-UTF-8 bytes of a PNG
    image_data = image_data.to_s.b
    return false unless bot && !image_data.empty?

    photo = Faraday::Multipart::FilePart.new(StringIO.new(image_data), "image/png", "qr.png")
    bot.api.send_photo(chat_id: chat_id, photo: photo, caption: caption)
    true
  end

  def update_last_notified(order, status)
    order.update_column(:last_notified_status, status)
  end

  def expire_minutes(order)
    (order.tenant || tenant).order_expire_minutes
  end

  def inline_keyboard(*rows)
    Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: rows)
  end

  def url_button(text, url) = Telegram::Bot::Types::InlineKeyboardButton.new(text: text, url: url)

  def callback_button(text, data) = Telegram::Bot::Types::InlineKeyboardButton.new(text: text, callback_data: data)

  # "после истечения срока счёта" / "после отмены заказа"
  def late_payment_reason(previous_status)
    previous_status == OrderStatus::CANCELLED ? "после отмены заказа" : "после истечения срока счёта"
  end

  # Amount in tyiyn -> "150.00 KGS"
  def format_tyiyn(amount)
    format("%.2f KGS", BigDecimal(amount.to_s) / 100)
  end
end
