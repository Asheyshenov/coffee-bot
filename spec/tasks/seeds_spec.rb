# frozen_string_literal: true

require "rails_helper"

RSpec.describe "db/seeds.rb", type: :task do
  def load_seeds(env: "development")
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(env))
    without_current_tenant do
      capture = StringIO.new
      original, $stdout = $stdout, capture
      load Rails.root.join("db/seeds.rb").to_s
      capture.string
    ensure
      $stdout = original
    end
  end

  def demo = ActsAsTenant.without_tenant { Tenant.find_by(slug: "demo") }

  it "creates the demo coffee shop with fake credentials, idempotently" do
    menu_service = class_double("MenuService").as_stubbed_const
    allow(menu_service).to receive(:seed_menu) do |tenant|
      ActsAsTenant.with_tenant(tenant) { MenuItem.exists? ? 0 : MenuItem.create!(category: "Кофе", name: "Латте", price: 15_000) && 1 }
    end

    2.times { load_seeds }

    expect(demo.bot).to have_attributes(username: "demo_coffee_bot", token: start_with("100000001:DEMO-FAKE"))
    expect(demo.payment_account).to have_attributes(sid: "demo-sid", test_mode: true, base_url: PaymentAccount::TEST_BASE_URL)
    ActsAsTenant.with_tenant(demo) do
      expect(StaffMember.pluck(:role)).to eq([ "owner" ])
      expect(MenuItem.count).to eq(1)
    end
    expect(menu_service).to have_received(:seed_menu).twice
    expect(ActsAsTenant.without_tenant { [ Bot.where(tenant: demo).count, PaymentAccount.where(tenant: demo).count ] }).to eq([ 1, 1 ])
  end

  it "falls back to a small menu without MenuService" do
    hide_const("MenuService")

    load_seeds

    expect(ActsAsTenant.with_tenant(demo) { MenuItem.order(:category, :position).pluck(:name) }).to eq(%w[Круассан Эспрессо Латте])
  end

  it "does nothing outside development (db:prepare seeds new production databases)" do
    expect(load_seeds(env: "production")).to include("skipped in production")
    expect(demo).to be_nil
  end
end
