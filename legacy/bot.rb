require 'telegram/bot'
require 'sequel'
require 'dotenv/load'

# Подключаем базу данных
DB = Sequel.sqlite('coffee.db')
Orders = DB[:orders]

# Загружаем переменные окружения
token = ENV['TELEGRAM_TOKEN']
barista_id = ENV['BARISTA_CHAT_ID']

Telegram::Bot::Client.run(token) do |bot|
  bot.listen do |message|
    case message
    when Telegram::Bot::Types::Message
      user_id = message.from.id
      username = message.from.first_name  # Используем имя пользователя
      text = message.text.strip

      # Приветствие и запрос на заказ
      if text.downcase == '/start'
        bot.api.send_message(chat_id: user_id, text: "Привет, #{username}! Напиши, что ты хочешь заказать ☕")
      else
        # Создаем новый заказ в базе данных
        order_id = Orders.insert(user_id: user_id, username: username, text: text, ready: false)
        
        # Создаем кнопки
        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: [
          [Telegram::Bot::Types::InlineKeyboardButton.new(text: "Заказ готов", callback_data: "ready_#{order_id}")]
        ])

        # Уведомляем баристу о новом заказе
        bot.api.send_message(chat_id: barista_id, text: "☕ Новый заказ ##{order_id}:\n#{text}", reply_markup: markup)

        # Подтверждаем заказ пользователю
        bot.api.send_message(chat_id: user_id, text: "Ваш заказ принят! Номер заказа: ##{order_id}")
      end

    when Telegram::Bot::Types::CallbackQuery
      if message.data.start_with?('ready_')
        order_id = message.data.split('_').last.to_i
        order = Orders.where(id: order_id).first

        # Проверка и обновление статуса заказа
        if order && !order[:ready]
          Orders.where(id: order_id).update(ready: true)
          
          # Уведомляем клиента о готовности заказа
          bot.api.send_message(chat_id: order[:user_id], text: "Ваш заказ ##{order_id} готов! ☕")
          
          # Ответ на callback
          bot.api.answer_callback_query(callback_query_id: message.id, text: "Клиент уведомлён")
        else
          bot.api.answer_callback_query(callback_query_id: message.id, text: "Заказ уже готов или не найден")
        end
      end
    end
  end
end