# frozen_string_literal: true

require "rails_helper"

RSpec.describe ShopBot::ResilientApi do
  let(:raw_api) { double("Telegram::Bot::Api") }
  let(:waits) { [] }
  let(:api) { described_class.new(raw_api, sleeper: ->(seconds) { waits << seconds }) }

  def throttled(retry_after)
    response = instance_double(Faraday::Response, status: 429, env: nil,
                               body: { ok: false, error_code: 429, description: "Too Many Requests",
                                       parameters: { retry_after: retry_after } }.to_json)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  it "passes calls through" do
    allow(raw_api).to receive(:send_message).with(chat_id: 1, text: "hi").and_return("ok" => true)

    expect(api.send_message(chat_id: 1, text: "hi")).to eq("ok" => true)
    expect(waits).to be_empty
  end

  it "waits retry_after on 429 and repeats only this call" do
    calls = 0
    allow(raw_api).to receive(:send_message) do
      calls += 1
      raise throttled(2) if calls == 1

      { "ok" => true }
    end

    expect(api.send_message(chat_id: 1, text: "hi")).to eq("ok" => true)
    expect(calls).to eq(2)
    expect(waits).to eq([ 2 ])
  end

  it "caps the wait and gives up after a few attempts" do
    allow(raw_api).to receive(:send_message).and_raise(throttled(60))

    expect { api.send_message(chat_id: 1, text: "hi") }.to raise_error(Telegram::Bot::Exceptions::ResponseError)
    expect(waits).to eq([ described_class::MAX_WAIT ] * (described_class::MAX_ATTEMPTS - 1))
  end

  it "retries network errors and re-raises other Telegram errors at once" do
    calls = 0
    allow(raw_api).to receive(:edit_message_text) do
      calls += 1
      raise Faraday::ConnectionFailed, "down" if calls == 1

      { "ok" => true }
    end
    bad_request = Telegram::Bot::Exceptions::ResponseError.new(
      response: instance_double(Faraday::Response, status: 400, env: nil, body: { ok: false, error_code: 400 }.to_json)
    )
    allow(raw_api).to receive(:answer_callback_query).and_raise(bad_request)

    expect(api.edit_message_text(chat_id: 1, message_id: 2, text: "x")).to eq("ok" => true)
    expect { api.answer_callback_query(callback_query_id: "q") }.to raise_error(Telegram::Bot::Exceptions::ResponseError)
    expect(calls).to eq(2)
  end

  it "is what Bot#api returns outside the spec stubs" do
    allow_any_instance_of(Bot).to receive(:api).and_call_original

    expect(current_tenant.bot.api).to be_a(described_class)
  end
end
