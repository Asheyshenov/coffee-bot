# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tenant isolation" do
  it "scopes every business model to the current coffee shop" do
    order = make_order
    other = create_tenant(slug: "other-shop")

    ActsAsTenant.with_tenant(other) do
      expect(Order.count).to eq(0)
      expect(Order.find_by(id: order.id)).to be_nil
      expect(Customer.count).to eq(0)
    end
    expect(Order.find(order.id)).to eq(order)
  end

  it "refuses queries without a tenant instead of mixing shops" do
    ActsAsTenant.without_tenant { nil } # sanity: the helper exists
    ActsAsTenant.current_tenant = nil
    expect { Order.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
  end

  it "lets the same Telegram user be a customer of two shops" do
    Customer.create!(telegram_user_id: 42)
    other = create_tenant(slug: "second-shop")

    expect { ActsAsTenant.with_tenant(other) { Customer.create!(telegram_user_id: 42) } }.not_to raise_error
  end

  it "keeps bot tokens and MWallet passwords encrypted at rest" do
    bot = current_tenant.bot
    account = current_tenant.payment_account

    raw_token = Bot.connection.select_value("SELECT token FROM bots WHERE id = #{bot.id}")
    raw_password = PaymentAccount.connection.select_value("SELECT password FROM payment_accounts WHERE id = #{account.id}")

    expect(raw_token).not_to include("123:TEST")
    expect(raw_password).not_to include(TenancyHelpers::MWALLET_SECRET)
    expect(bot.reload.token).to eq("123:TEST")
  end

  it "rejects invalid order statuses at the database level" do
    order = make_order
    expect { order.update_column(:status, "cancelled") }.to raise_error(ActiveRecord::StatementInvalid, /orders_status_check/)
  end

  it "runs tenant jobs inside the job's tenant" do
    seen = nil
    job = Class.new(TenantJob) { define_method(:perform_in_tenant) { |id| seen = [ ActsAsTenant.current_tenant.id, Order.find(id).id ] } }
    order = make_order
    tenant_id = current_tenant.id

    ActsAsTenant.current_tenant = nil
    job.new.perform(tenant_id, order.id)

    expect(seen).to eq([ tenant_id, order.id ])
  end

  it "deletes a coffee shop with all its data (orders, callback logs, bot updates)" do
    tenant = current_tenant
    make_order
    CallbackLog.log_callback(payment_account: tenant.payment_account, raw_body: "{}", invoice_id: "INV-1")
    TelegramUpdate.accept?(tenant.bot, 1)

    ActsAsTenant.without_tenant { tenant.destroy! }

    ActsAsTenant.without_tenant do
      expect(Tenant.exists?(tenant.id)).to be(false)
      expect([ Order, CallbackLog, PaymentAccount, Bot, TelegramUpdate ].map(&:count)).to all(eq(0))
    end
  end
end
