# frozen_string_literal: true

# Records every Telegram API call. Like real Telegram, a second answer for the same
# callback query is rejected (recorded as :answer_callback_query_rejected).
class FakeTelegramApi
  attr_reader :calls

  def initialize
    @calls = []
    @answered = {}
  end

  def method_missing(name, **kwargs)
    if name == :answer_callback_query
      id = kwargs[:callback_query_id]
      if @answered[id]
        @calls << [ :answer_callback_query_rejected, kwargs ]
        return { "ok" => false }
      end
      @answered[id] = true
    end
    @calls << [ name, kwargs ]
    { "ok" => true, "result" => {} }
  end

  def respond_to_missing?(*) = true

  def of(name) = calls.select { |(n, _)| n == name }.map(&:last)
  def texts = calls.map { |(_, kw)| kw[:text] }.compact
  def messages_to(chat_id) = of(:send_message).select { |m| m[:chat_id] == chat_id }
end

# telegram-bot-ruby 2.4 autoloads its types; autoloading CallbackQuery before Message
# hits a circular reference. Loading Message first avoids it.
Telegram::Bot::Types::Message

module TelegramUpdateHelpers
  def tg_user(id) = { id: id, is_bot: false, first_name: "U#{id}" }
  def tg_chat(id) = { id: id, type: "private" }

  def text_msg(text, from: client_id)
    Telegram::Bot::Types::Message.new(message_id: rand(1..10_000), date: 0, chat: tg_chat(from), from: tg_user(from), text: text)
  end

  def non_text_msg(from: client_id)
    Telegram::Bot::Types::Message.new(message_id: rand(1..10_000), date: 0, chat: tg_chat(from), from: tg_user(from))
  end

  def cb(data, from: client_id, id: "q#{rand(1_000_000)}")
    Telegram::Bot::Types::CallbackQuery.new(
      id: id, from: tg_user(from), chat_instance: "x", data: data,
      message: { message_id: 77, date: 0, chat: tg_chat(from) }
    )
  end
end
