# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mini App API: orders", type: :request do
  include_context "shop menu"

  let(:invoice_response) do
    { "data" => { "invoice_id" => "INV-MA-1", "paylink_url" => "https://pay.example/INV-MA-1",
                  "emv_qr" => "https://pay.example/qr.php?id=INV-MA-1",
                  "link_app" => "https://o.kg/l/a?t=wl_unpbill&id=INV-MA-1" } }
  end

  def stub_create_invoice(response = invoice_response)
    allow_any_instance_of(MWallet::Client).to receive(:create_invoice).and_return(response)
  end

  def place_order(body = {}) = mini_app_post("orders", body)

  describe "POST /orders" do
    before do
      travel_to Time.zone.local(2026, 9, 28, 12, 0, 0)
      stub_create_invoice
    end

    it "creates the order and its invoice from the cart, clears the cart and returns the order" do
      draft = draft_with_latte(qty: 2)
      draft.add_item(croissant, 1)

      place_order(comment: "без сахара")

      expect(response).to have_http_status(:created)
      order = Order.sole
      expect(json_body).to eq(
        "id" => order.id, "status" => "INVOICE_CREATED", "status_text" => "Ожидает оплату",
        "created_at" => "2026-09-28T12:00:00+06:00",
        "items" => [ { "name" => "Латте (M)", "qty" => 2, "line_total" => 30_000 },
                     { "name" => "Круассан", "qty" => 1, "line_total" => 12_000 } ],
        "total" => 42_000, "comment" => "без сахара",
        "payment" => { "app_url" => "https://o.kg/l/a?t=wl_unpbill&id=INV-MA-1",
                       "paylink_url" => "https://pay.example/INV-MA-1",
                       "qr_image_url" => "https://pay.example/qr.php?id=INV-MA-1",
                       "expires_at" => "2026-09-28T12:15:00+06:00" },
        "refund_required" => false, "can_cancel" => true
      )
      expect(order).to have_attributes(customer: Customer.find_by!(telegram_user_id: client_id), telegram_user_id: client_id,
                                       invoice_id_provider: "INV-MA-1", payment_account: current_tenant.payment_account,
                                       payment_app_url: "https://o.kg/l/a?t=wl_unpbill&id=INV-MA-1",
                                       comment: "без сахара")
      expect(Draft.for_user(client_id)).to be_nil # the chat bot's cart is empty too
    end

    it "schedules the payment polling and expiry like the chat checkout, without a chat QR message" do
      draft_with_latte

      expect { place_order }.to have_enqueued_job(Payments::PollStatusJob)
        .and have_enqueued_job(Payments::ExpireInvoiceJob)

      expect(api.calls).to be_empty
    end

    it "issues the invoice with the order total at MWallet" do
      draft_with_latte(qty: 3)
      expect_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .with(hash_including(amount: 45_000, order_id: start_with("ORDER-"))).and_return(invoice_response)

      place_order

      expect(response).to have_http_status(:created)
    end

    it "keeps the cart's comment (e.g. typed in the chat) without a comment key" do
      draft_with_latte.set_comment("из чата")

      place_order

      expect(response).to have_http_status(:created)
      expect(Order.sole.comment).to eq("из чата")
    end

    it "truncates the comment to 200 characters" do
      draft_with_latte

      place_order(comment: "x" * 250)

      expect(json_body["comment"]).to eq("x" * 200)
    end

    it "clears the comment for a blank or null comment" do
      draft_with_latte.set_comment("из чата")

      place_order(comment: "  ")

      expect(json_body["comment"]).to be_nil
    end

    it "answers 422 invalid_comment for a comment that is not a string" do
      draft_with_latte

      place_order(comment: { "text" => "x" })

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "invalid_comment")
      expect(Order.count).to eq(0)
    end

    it "uses the order total from the menu for a chat cart that is up to date" do
      draft_with_latte(qty: 2)

      place_order

      expect(json_body["total"]).to eq(30_000)
    end

    describe "409 cart_changed" do
      it "on a price change: nothing is ordered, the repriced cart is returned, the next attempt succeeds" do
        draft_with_latte(qty: 2)
        latte.update!(sizes: latte.sizes.merge("medium" => 16_000))

        place_order

        expect(response).to have_http_status(:conflict)
        expect(json_body).to include("error" => "cart_changed", "removed" => [], "repriced" => [ "Латте (M)" ])
        expect(json_body["cart"]).to include("total" => 32_000)
        expect(json_body["cart"]["items"].first).to include("unit_price" => 16_000, "line_total" => 32_000)
        expect(Order.count).to eq(0)

        place_order
        expect(response).to have_http_status(:created)
        expect(json_body["total"]).to eq(32_000)
      end

      it "on an item that is no longer available: the line is removed" do
        draft_with_latte.add_item(croissant, 1)
        croissant.update!(available: false)

        place_order

        expect(response).to have_http_status(:conflict)
        expect(json_body).to include("error" => "cart_changed", "removed" => [ "Круассан" ], "repriced" => [])
        expect(json_body["cart"]["items"].pluck("name")).to eq([ "Латте" ])
        expect(Order.count).to eq(0)
      end

      it "then 422 empty_cart when nothing is left" do
        Draft.get_or_create(client_id).add_item(croissant, 1)
        croissant.update!(available: false)

        place_order
        expect(response).to have_http_status(:conflict)
        expect(json_body["cart"]["items"]).to eq([])

        place_order
        expect(response).to have_http_status(:unprocessable_content)
        expect(json_body).to eq("error" => "empty_cart")
      end
    end

    it "answers 422 empty_cart without a cart or for an empty one" do
      place_order
      expect(response).to have_http_status(:unprocessable_content)
      expect(json_body).to eq("error" => "empty_cart")

      Draft.get_or_create(client_id)
      place_order
      expect(json_body).to eq("error" => "empty_cart")
      expect(Order.count).to eq(0)
    end

    describe "502 invoice_failed" do
      it "hides the provider's text and keeps the cart for a retry" do
        draft_with_latte(qty: 2)
        allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
          .and_raise(MWalletError::BusinessError.new("Неверная подпись sid 5050", code: 7))

        place_order

        expect(response).to have_http_status(:bad_gateway)
        expect(json_body).to eq("error" => "invoice_failed")
        expect(Draft.for_user(client_id).items.first).to include("qty" => 2)
        expect(Order.sole.status).to eq(OrderStatus::ERROR)
        expect(api.calls).to be_empty

        stub_create_invoice
        place_order
        expect(response).to have_http_status(:created)
        expect(Draft.for_user(client_id)).to be_nil
      end

      it "on a timeout" do
        draft_with_latte
        allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
          .and_raise(MWalletError::ProviderTimeout, "Request failed after 3 retries: execution expired")

        place_order

        expect(response).to have_http_status(:bad_gateway)
        expect(json_body).to eq("error" => "invoice_failed")
      end

      it "when the shop has no active payment account" do
        draft_with_latte
        current_tenant.payment_account.update!(active: false)

        place_order

        expect(response).to have_http_status(:bad_gateway)
        expect(json_body).to eq("error" => "invoice_failed")
        expect(Draft.for_user(client_id)).not_to be_empty
      end
    end
  end

  describe "GET /orders and /orders/:id" do
    def open_order(**options)
      make_order(**options).tap do |order|
        order.update!(qr_url: "https://pay.example/#{order.id}", emv_qr_url: "https://pay.example/qr.php?id=#{order.id}",
                      payment_app_url: "https://o.kg/l/a?t=wl_unpbill&id=#{order.id}")
      end
    end

    it "shows an open order with its payment block, times in the shop's time zone" do
      travel_to Time.utc(2026, 9, 28, 6, 0, 0)
      current_tenant.update!(time_zone: "Europe/Moscow", order_expire_minutes: 20)
      order = open_order
      order.update!(comment: "с собой")

      mini_app_get("orders/#{order.id}")

      expect(response).to have_http_status(:ok)
      expect(json_body).to eq(
        "id" => order.id, "status" => "INVOICE_CREATED", "status_text" => "Ожидает оплату",
        "created_at" => "2026-09-28T09:00:00+03:00",
        "items" => [ { "name" => "Латте", "qty" => 1, "line_total" => 15_000 } ],
        "total" => 15_000, "comment" => "с собой",
        "payment" => { "app_url" => "https://o.kg/l/a?t=wl_unpbill&id=#{order.id}",
                       "paylink_url" => "https://pay.example/#{order.id}",
                       "qr_image_url" => "https://pay.example/qr.php?id=#{order.id}",
                       "expires_at" => "2026-09-28T09:20:00+03:00" },
        "refund_required" => false, "can_cancel" => true
      )
    end

    it "has no payment block once the order is paid, and cannot be cancelled" do
      order = open_order(status: OrderStatus::PAID)

      mini_app_get("orders/#{order.id}")

      expect(json_body).to include("status" => "PAID", "status_text" => "Оплачен", "payment" => nil, "can_cancel" => false)
    end

    it "marks a late payment that must be refunded" do
      order = open_order(status: OrderStatus::CANCELLED)
      Payment.create!(order: order, status: PaymentStatus::REFUND_REQUIRED, paid_amount: 15_000)

      mini_app_get("orders/#{order.id}")

      expect(json_body).to include("status" => "CANCELLED", "refund_required" => true, "payment" => nil,
                                   "can_cancel" => false)
    end

    it "can cancel a NEW order" do
      order = make_order(status: OrderStatus::NEW, invoice: nil)

      mini_app_get("orders/#{order.id}")

      expect(json_body).to include("status" => "NEW", "payment" => nil, "can_cancel" => true)
    end

    it "lists the customer's latest 10 orders, newest first" do
      orders = Array.new(12) do |i|
        travel_to(Time.zone.local(2026, 9, 28, 8, i)) { make_order(status: OrderStatus::READY, invoice: "INV-#{i}") }
      end
      travel_to(Time.zone.local(2026, 9, 28, 9, 0)) { make_order(user_id: stranger_id, invoice: "INV-S") }

      mini_app_get("orders")

      expect(response).to have_http_status(:ok)
      expect(json_body["orders"].pluck("id")).to eq(orders.reverse.first(10).map(&:id))
      expect(json_body["orders"].first).to include("status" => "READY", "items" => [ hash_including("name" => "Латте") ])
    end

    it "lists nothing for a new customer" do
      mini_app_get("orders")

      expect(json_body).to eq("orders" => [])
    end

    it "answers 404 for another customer's order" do
      order = make_order(user_id: stranger_id)

      mini_app_get("orders/#{order.id}")

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
    end

    it "answers 404 for another shop's order of the same Telegram user, and does not list it" do
      shop_b = other_tenant
      order_b = ActsAsTenant.with_tenant(shop_b) { make_order(invoice: "INV-B") }

      mini_app_get("orders/#{order_b.id}")
      expect(response).to have_http_status(:not_found)

      mini_app_get("orders")
      expect(json_body["orders"]).to eq([])
    end

    [ "abc", "0", "1.5" ].each do |id|
      it "answers 404 for the id #{id.inspect}" do
        mini_app_get("orders/#{id}")

        expect(response).to have_http_status(:not_found)
        expect(json_body).to eq("error" => "not_found")
      end
    end
  end

  describe "POST /orders/:id/cancel" do
    def cancel(order) = mini_app_post("orders/#{order.id}/cancel")

    def invoice_cancel_returns(response)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return(response)
    end

    context "with an unpaid invoice" do
      let!(:order) { make_order(invoice: "INV-C") }

      before { provider_returns("status" => "processing") }

      it "cancels it at MWallet and locally" do
        invoice_cancel_returns({ "data" => { "success" => true } })

        cancel(order)

        expect(response).to have_http_status(:ok)
        expect(json_body["outcome"]).to eq("cancelled")
        expect(json_body["order"]).to include("id" => order.id, "status" => "CANCELLED", "status_text" => "Отменён",
                                              "payment" => nil, "can_cancel" => false)
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end

      it "returns cancelled_locally when MWallet does not confirm the invoice cancel" do
        invoice_cancel_returns({ "data" => { "success" => false } })

        cancel(order)

        expect(json_body["outcome"]).to eq("cancelled_locally")
        expect(order.reload.status).to eq(OrderStatus::CANCELLED)
      end
    end

    it "returns paid_now and sends the payment notifications once when the last-chance check finds the payment" do
      order = make_order(invoice: "INV-PAID-NOW")
      provider_confirms(amount: 15_000)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      expect { cancel(order) }.to have_enqueued_job(Payments::NotifyResultJob).exactly(:once)

      expect(json_body["outcome"]).to eq("paid_now")
      expect(json_body["order"]).to include("status" => "PAID", "payment" => nil, "can_cancel" => false)
      perform_notifications
      expect(texts_to(barista_id).grep(/Новый заказ ##{order.id}/).size).to eq(1)
    end

    it "returns payment_problem when the last-chance check finds an underpayment" do
      order = make_order(invoice: "INV-LOW")
      provider_confirms(amount: 10_000)

      expect { cancel(order) }.to have_enqueued_job(Payments::NotifyResultJob)

      expect(json_body["outcome"]).to eq("payment_problem")
      expect(json_body["order"]["status"]).to eq("ERROR")
    end

    it "cancels a NEW order without invoice" do
      order = make_order(status: OrderStatus::NEW, invoice: nil)

      cancel(order)

      expect(json_body["outcome"]).to eq("cancelled")
      expect(order.reload.status).to eq(OrderStatus::CANCELLED)
    end

    {
      OrderStatus::PAID => "already_paid",
      OrderStatus::IN_PROGRESS => "in_progress",
      OrderStatus::CANCELLED => "cancelled",
      OrderStatus::EXPIRED => "not_cancellable",
      OrderStatus::READY => "not_cancellable"
    }.each do |status, outcome|
      it "returns #{outcome} for a #{status} order and leaves it as is" do
        order = make_order(status: status)
        expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

        expect { cancel(order) }.not_to have_enqueued_job(Payments::NotifyResultJob)

        expect(response).to have_http_status(:ok)
        expect(json_body).to include("outcome" => outcome, "order" => hash_including("status" => status))
        expect(order.reload.status).to eq(status)
      end
    end

    it "answers 404 for another customer's order and does not cancel it" do
      order = make_order(user_id: stranger_id)
      expect_any_instance_of(MWallet::Client).not_to receive(:cancel_invoice)

      cancel(order)

      expect(response).to have_http_status(:not_found)
      expect(json_body).to eq("error" => "not_found")
      expect(order.reload.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it "answers 404 for another shop's order" do
      order_b = ActsAsTenant.with_tenant(other_tenant) { make_order(invoice: "INV-B") }

      cancel(order_b)

      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.without_tenant { order_b.reload.status }).to eq(OrderStatus::INVOICE_CREATED)
    end
  end
end
