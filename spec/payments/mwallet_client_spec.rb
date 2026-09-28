# frozen_string_literal: true

require "rails_helper"

RSpec.describe MWallet::Client do
  subject(:client) do
    described_class.new(base_url: "https://mwallet.test/api/json/json.php", sid: "123", password: "secret", version: 1005,
                        timeout: 1, retry_count: 0, test_mode: true)
  end

  # Records [path, signed params] of every POST and answers with the given body
  def stub_post(response_body, status: 200)
    sent = []
    allow_any_instance_of(Faraday::Connection).to receive(:post) do |_conn, path, body|
      sent << [ path, body ]
      instance_double(Faraday::Response, success?: status.between?(200, 299), status: status, body: response_body)
    end
    sent
  end

  describe "#cancel_invoice" do
    it 'uses the case-sensitive "invoiceCancel" command (the sandbox rejects "InvoiceCancel")' do
      sent = stub_post({ "data" => { "success" => true } })

      expect(client.cancel_invoice("550362450351")).to eq({ "data" => { "success" => true } })
      path, params = sent.first
      expect(path).to eq("/api/json/json.php")
      expect(params).to include("cmd" => "invoiceCancel", "sid" => "123", "version" => 1005,
                                "data" => { "invoice_id" => "550362450351" })
      expect(params["hash"]).to match(/\A\h{32}\z/)
    end

    it 'raises a business error for the top-level {"error":2,"desc":"Команда не определена"}' do
      stub_post({ "error" => 2, "desc" => "Команда не определена" })

      expect { client.cancel_invoice("1") }.to raise_error(MWalletError::BusinessError, "Команда не определена") { |e|
        expect(e.code).to eq(2)
      }
    end

    it "raises a business error for an error inside data" do
      stub_post({ "data" => { "error" => 2, "desc" => "Команда не определена" } })

      expect { client.cancel_invoice("1") }.to raise_error(MWalletError::BusinessError, "Команда не определена")
    end

    it 'does not treat "error": 0 as an error' do
      stub_post({ "error" => 0, "data" => { "success" => true } })

      expect(client.cancel_invoice("1")).to include("data" => { "success" => true })
    end
  end

  describe "#get_status" do
    it "sends statusPayment for the invoice and returns the body" do
      sent = stub_post({ "data" => { "status" => "processing" } })

      expect(client.get_status("INV-1")).to eq({ "data" => { "status" => "processing" } })
      expect(sent.first.last).to include("cmd" => "statusPayment", "data" => { "invoice_id" => "INV-1" })
    end

    it "parses a JSON body served with a non-JSON content type" do
      stub_post('{"data":{"status":"approved"}}')

      expect(client.get_status("INV-1")).to eq({ "data" => { "status" => "approved" } })
    end

    it "raises a business error for a body that is not JSON" do
      stub_post("<html>maintenance</html>")

      expect { client.get_status("INV-1") }.to raise_error(MWalletError::BusinessError, "Unexpected MWallet response")
    end
  end

  describe "#create_invoice" do
    it "sends a signed createInvoice with the merchant's data and without empty fields" do
      sent = stub_post({ "data" => { "invoice_id" => "INV-9" } })

      client.create_invoice(order_id: "ORDER-1", desc: "Заказ #1", amount: 15_000, result_url: "https://app.test/pay/mwallet/1",
                            date_life: 900)

      params = sent.first.last
      expect(params["cmd"]).to eq("createInvoice")
      expect(params["data"]).to eq("order_id" => "ORDER-1", "desc" => "Заказ #1", "amount" => 15_000, "currency" => "KGS",
                                   "test" => 1, "date_life" => 900, "count_push" => 1, "send_push" => 1,
                                   "result_url" => "https://app.test/pay/mwallet/1")
      # Signed with the merchant password over the JSON without "hash"
      expect(MWallet::Signer.new("secret").verify_callback(params)).to be(true)
      expect(MWallet::Signer.new("other").verify_callback(params)).to be(false)
    end

    it "omits the test flag in production mode" do
      sent = stub_post({ "data" => { "invoice_id" => "INV-9" } })
      live = described_class.new(base_url: "https://mwallet.test", sid: "1", password: "p", test_mode: false, retry_count: 0)

      live.create_invoice(order_id: "O", amount: 100)

      expect(sent.first.first).to eq(MWallet::Client::DEFAULT_PATH) # bare host gets the API path
      expect(sent.first.last["data"]).not_to have_key("test")
    end
  end

  describe "transport errors" do
    it "raises ProviderTimeout on a timeout" do
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_raise(Faraday::TimeoutError, "execution expired")

      expect { client.get_status("1") }.to raise_error(MWalletError::ProviderTimeout)
    end

    it "retries timeouts and connection failures with backoff" do
      retrying = described_class.new(base_url: "https://mwallet.test", sid: "1", password: "p", retry_count: 2)
      allow(retrying).to receive(:sleep)
      calls = 0
      allow_any_instance_of(Faraday::Connection).to receive(:post) do
        calls += 1
        raise Faraday::ConnectionFailed, "refused" if calls < 3

        instance_double(Faraday::Response, success?: true, status: 200, body: { "data" => { "status" => "processing" } })
      end

      expect(retrying.get_status("1")).to eq({ "data" => { "status" => "processing" } })
      expect(retrying).to have_received(:sleep).with(2).ordered
      expect(retrying).to have_received(:sleep).with(4).ordered
    end

    it "raises NetworkError for other Faraday errors" do
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_raise(Faraday::SSLError, "bad cert")

      expect { client.get_status("1") }.to raise_error(MWalletError::NetworkError)
    end

    it "classifies HTTP errors" do
      stub_post({ "message" => "boom" }, status: 502)
      expect { client.get_status("1") }.to raise_error(MWalletError::NetworkError, /Provider error/)

      stub_post({}, status: 401)
      expect { client.get_status("1") }.to raise_error(MWalletError::SignatureError)

      stub_post({}, status: 504)
      expect { client.get_status("1") }.to raise_error(MWalletError::ProviderTimeout)
    end
  end

  it "never logs the password or signatures" do
    stub_post({ "data" => { "success" => true } })
    logged = []
    allow(Rails.logger).to receive(:debug) { |*args, &block| logged << (block ? block.call : args.first) }

    client.cancel_invoice("1")

    expect(logged.join).to include("invoiceCancel")
    expect(logged.join).not_to include("secret")
    expect(logged.join).not_to match(/\h{32}/)
  end

  it 'maps the sandbox status of a cancelled invoice ("canceled")' do
    expect(MWallet::StatusMapper.map_from_provider("canceled")).to eq(:cancelled)
  end

  describe "retries" do
    subject(:retrying_client) do
      described_class.new(base_url: "https://mwallet.test/api/json/json.php", sid: "123", password: "secret",
                          timeout: 1, retry_count: 2, test_mode: true)
    end

    def fail_first(error)
      calls = 0
      allow_any_instance_of(Faraday::Connection).to receive(:post) do
        calls += 1
        raise error if calls == 1

        instance_double(Faraday::Response, success?: true, status: 200, body: { "data" => { "invoice_id" => "1" } })
      end
      allow(retrying_client).to receive(:sleep)
      -> { calls }
    end

    it "never repeats createInvoice after a read timeout (MWallet may have created the invoice)" do
      calls = fail_first(Faraday::TimeoutError.new("read timeout"))

      expect { retrying_client.create_invoice(order_id: "O-1", amount: 100) }.to raise_error(MWalletError::ProviderTimeout)
      expect(calls.call).to eq(1)
    end

    it "repeats createInvoice when the connection could not be opened (nothing was sent)" do
      calls = fail_first(Faraday::ConnectionFailed.new("connection refused"))

      expect(retrying_client.create_invoice(order_id: "O-1", amount: 100)).to eq("data" => { "invoice_id" => "1" })
      expect(calls.call).to eq(2)
    end

    it "repeats read-only statusPayment after a read timeout" do
      calls = fail_first(Faraday::TimeoutError.new("read timeout"))

      retrying_client.get_status("1")
      expect(calls.call).to eq(2)
    end
  end
end
