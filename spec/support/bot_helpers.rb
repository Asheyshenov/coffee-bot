# frozen_string_literal: true

# Helpers for specs that drive ShopBot::Router of the current coffee shop.
#
#   RSpec.describe "..." do
#     include_context "shop bot"
#     it { dispatch(text_msg("/start")) }
#   end
RSpec.shared_context "shop bot" do
  let(:router) { ShopBot::Router.new(current_tenant.bot) }

  # Handle an update like ShopBot::ProcessUpdateJob does, then deliver the payment
  # notifications the router queued (Payments::NotifyResultJob), as the queue would
  # right after. Invoice polling and expiry jobs stay queued.
  def dispatch(update)
    router.handle(update).tap { deliver_payment_notifications }
  end

  def deliver_payment_notifications
    perform_enqueued_jobs(only: ->(job) { job.fetch(:job).name == "Payments::NotifyResultJob" })
  end

  # The job logs router errors instead of raising: return the error for inspection
  def dispatch_like_job(update)
    dispatch(update)
    nil
  rescue StandardError => e
    e
  end

  # Stub the MWallet statusPayment response
  def provider_reports(status, amount: 15_000)
    allow_any_instance_of(MWallet::Client).to receive(:get_status)
      .and_return({ "data" => { "payments" => [ { "status" => status, "amount" => amount } ] } })
  end

  # MWallet invoiceCancel response that confirms the cancel
  def cancel_confirmed = { "data" => { "success" => true } }

  def stub_invoice_creation(invoice_id: "INV-NEW")
    allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
      .and_return({ "data" => { "invoice_id" => invoice_id, "paylink_url" => "https://pay.example/#{invoice_id}" } })
  end

  def add_barista(telegram_user_id) = StaffMember.create!(telegram_user_id: telegram_user_id, role: "barista")

  def barista_new_order_messages
    api.messages_to(barista_id).select { |m| m[:text].include?("Новый заказ") }
  end

  def denial_alerts
    api.of(:answer_callback_query).select { |a| a[:text]&.include?("⛔") && a[:show_alert] }
  end

  def cart = Draft.get_or_create(client_id)

  def customer(telegram_user_id = client_id)
    Customer.find_by(telegram_user_id: telegram_user_id) ||
      Customer.create!(telegram_user_id: telegram_user_id, first_name: "Test")
  end
end

RSpec.shared_context "shop menu" do
  let!(:latte) do
    MenuItem.create!(category: "☕ Кофе", name: "Латте", price: 15_000,
                     sizes: { "small" => 13_000, "medium" => 15_000, "large" => 19_000 }, default_size: "medium")
  end
  let!(:croissant) { MenuItem.create!(category: "🍰 Десерты", name: "Круассан", price: 12_000) }

  def draft_with_latte(user_id: client_id, qty: 1)
    draft = Draft.get_or_create(user_id)
    draft.add_item_with_size(latte, "medium", qty)
    draft
  end
end
