# frozen_string_literal: true

# Every example runs inside a coffee shop (tenant) with a bot, an MWallet account,
# one barista and a fake Telegram API. Examples can switch tenants with
# ActsAsTenant.with_tenant(other_tenant) { ... }.
module TenancyHelpers
  CLIENT_ID = 1001
  BARISTA_ID = 2002
  STRANGER_ID = 3003
  MWALLET_SECRET = "test-secret"

  def create_tenant(slug: "shop-#{SecureRandom.hex(3)}", name: "Test Coffee", barista_ids: [BARISTA_ID])
    ActsAsTenant.without_tenant do
      tenant = Tenant.create!(name: name, slug: slug)
      Bot.create!(tenant: tenant, telegram_bot_id: rand(10**9), username: "#{slug.tr('-', '_')}_bot", token: "123:TEST")
      PaymentAccount.create!(tenant: tenant, sid: "5050", password: MWALLET_SECRET, base_url: PaymentAccount::TEST_BASE_URL)
      barista_ids.each { |id| StaffMember.create!(tenant: tenant, telegram_user_id: id, role: "barista") }
      tenant
    end
  end

  def make_order(status: OrderStatus::INVOICE_CREATED, user_id: CLIENT_ID, total: 15_000, invoice: "INV-1")
    customer = Customer.create_or_find_by!(telegram_user_id: user_id)
    order = Order.create!(customer: customer, telegram_user_id: user_id, client_display_name: "Test", status: status,
                          total_amount: total, merchant_invoice_id: Order.generate_merchant_invoice_id,
                          invoice_id_provider: invoice, payment_account: current_tenant.payment_account)
    order.order_items.create!(item_name: "Латте", qty: 1, unit_price: total, line_total: total)
    order
  end

  def current_tenant = ActsAsTenant.current_tenant
end

RSpec.configure do |config|
  config.include TenancyHelpers
  config.include TelegramUpdateHelpers

  # The tenant is created in its own transaction that is always rolled back: `around`
  # runs outside the transactional-fixture transaction (opened in a before hook),
  # so without it every example would leave a tenant, bot and account behind.
  config.around do |example|
    ActiveRecord::Base.transaction(requires_new: true) do
      tenant = create_tenant
      ActsAsTenant.with_tenant(tenant) { example.run }
      raise ActiveRecord::Rollback
    end
  ensure
    ActsAsTenant.current_tenant = nil
  end

  config.before do
    @fake_telegram = FakeTelegramApi.new
    allow_any_instance_of(Bot).to receive(:api).and_return(@fake_telegram)
    allow(Telegram::Bot::Client).to receive(:new).and_return(Struct.new(:api).new(@fake_telegram))
  end
end

module FakeTelegramAccess
  def api = @fake_telegram
  def client_id = TenancyHelpers::CLIENT_ID
  def barista_id = TenancyHelpers::BARISTA_ID
  def stranger_id = TenancyHelpers::STRANGER_ID
end

RSpec.configure { |config| config.include FakeTelegramAccess }
