# frozen_string_literal: true

require "rails_helper"

RSpec.describe TelegramInitData do
  let(:token) { MiniAppApiHelpers::TEST_BOT_TOKEN }

  def verify(init_data, bot_token: token, **options) = described_class.verify(init_data, bot_token: bot_token, **options)

  it "accepts initData signed with the bot's token and parses the user JSON" do
    data = verify(init_data_for(user_id: 42, user: { first_name: "Айбек", username: "aibek" }))

    expect(data["user"]).to include("id" => 42, "first_name" => "Айбек", "username" => "aibek", "language_code" => "ru")
    expect(data["auth_date"]).to be_within(5).of(Time.current.to_i)
    expect(data["query_id"]).to eq("AAHdF6IQAAAAAN0XohDhrOrc")
    expect(data).not_to have_key("hash")
  end

  it "checks every field, not only the user (sorted data-check-string)" do
    init_data = init_data_for(chat_type: "private", chat_instance: "-123", start_param: "promo")

    expect(verify(init_data)).to include("chat_type" => "private", "chat_instance" => "-123", "start_param" => "promo")
  end

  it "accepts an upper-case hex hash" do
    fields = URI.decode_www_form(init_data_for).to_h

    expect { verify(URI.encode_www_form(fields.merge("hash" => fields["hash"].upcase))) }.not_to raise_error
  end

  it "rejects tampered data (user id changed after signing)" do
    expect { verify(tampered_init_data) }.to raise_error(described_class::Invalid, "hash mismatch")
  end

  it "rejects a changed hash" do
    fields = URI.decode_www_form(init_data_for).to_h
    fields["hash"] = fields["hash"].sub(/\A./) { |c| c == "0" ? "1" : "0" }

    expect { verify(URI.encode_www_form(fields)) }.to raise_error(described_class::Invalid, "hash mismatch")
  end

  it "rejects data signed with another bot's token" do
    expect { verify(init_data_for(bot_token: "456:OTHER")) }.to raise_error(described_class::Invalid, "hash mismatch")
  end

  it "rejects data signed with the token directly instead of the WebAppData-derived key" do
    fields = { "auth_date" => Time.current.to_i.to_s, "user" => { id: 1 }.to_json }
    data_check_string = fields.sort.map { |k, v| "#{k}=#{v}" }.join("\n")
    forged = URI.encode_www_form(fields.merge("hash" => OpenSSL::HMAC.hexdigest("SHA256", token, data_check_string)))

    expect { verify(forged) }.to raise_error(described_class::Invalid, "hash mismatch")
  end

  it "rejects an expired auth_date and honours max_age" do
    expect { verify(expired_init_data) }.to raise_error(described_class::Invalid, "init data expired")
    expect { verify(init_data_for(auth_date: 2.hours.ago.to_i), max_age: 1.hour) }
      .to raise_error(described_class::Invalid, "init data expired")
    expect(verify(init_data_for(auth_date: 23.hours.ago.to_i))["auth_date"]).to be_a(Integer)
  end

  it "rejects a missing or non-numeric auth_date" do
    fields = { "user" => { id: 1 }.to_json }

    expect { verify(signed_init_data(fields)) }.to raise_error(described_class::Invalid, "auth_date missing")
    expect { verify(signed_init_data(fields.merge("auth_date" => "yesterday"))) }
      .to raise_error(described_class::Invalid, "auth_date missing")
  end

  it "rejects a missing or malformed hash" do
    without_hash = URI.encode_www_form(URI.decode_www_form(init_data_for).to_h.except("hash"))

    expect { verify(without_hash) }.to raise_error(described_class::Invalid, "hash missing or malformed")
    expect { verify("#{without_hash}&hash=xyz") }.to raise_error(described_class::Invalid, "hash missing or malformed")
  end

  it "rejects missing, oversized, duplicated and malformed input" do
    [ nil, "", 42 ].each do |value|
      expect { verify(value) }.to raise_error(described_class::Invalid, "init data missing")
    end
    expect { verify("a=#{'x' * 9000}") }.to raise_error(described_class::Invalid, "init data too long")
    expect { verify("#{init_data_for}&auth_date=1") }.to raise_error(described_class::Invalid, "duplicate field")
    expect { verify("user=%E0%A4%A&hash=#{'0' * 64}") }.to raise_error(described_class::Invalid)
    expect { verify("user=Айбек") }.to raise_error(described_class::Invalid, "init data malformed")
  end

  it "rejects a blank bot token" do
    expect { verify(init_data_for, bot_token: nil) }.to raise_error(described_class::Invalid, "bot token missing")
  end

  it "rejects a signed user that is not a JSON object" do
    base = { "auth_date" => Time.current.to_i.to_s }

    expect { verify(signed_init_data(base.merge("user" => "{not json"))) }
      .to raise_error(described_class::Invalid, "user is not valid JSON")
    expect { verify(signed_init_data(base.merge("user" => "[1]"))) }
      .to raise_error(described_class::Invalid, "user is not an object")
  end

  it "accepts data without a user (the caller decides whether it needs one)" do
    expect(verify(init_data_for(user: nil))).not_to have_key("user")
  end
end
