# frozen_string_literal: true

require "rails_helper"

# Every example already runs inside another coffee shop (spec/support/tenancy.rb):
# the tasks must not depend on the current tenant.
RSpec.describe "tenants rake tasks", type: :task do
  let(:shop) { ActsAsTenant.without_tenant { Tenant.create!(slug: "corner", name: "Corner Coffee") } }
  let(:bot_token) { "777000111:AAH-secret-bot-token" }
  let(:mwallet_password) { "super-secret-mwallet-password" }
  let(:production_url) { "https://mwallet.example.kg/api/json/json.php" }

  # Every legacy variable is overridden: the real .env is loaded in tests
  let(:legacy_env) do
    {
      "TELEGRAM_BOT_TOKEN" => bot_token, "MWALLET_SID" => "20250042", "MWALLET_PASSWORD" => mwallet_password,
      "MWALLET_TEST_MODE" => "true", "MWALLET_API_VERSION" => nil, "MWALLET_BASE_URL" => nil,
      "MWALLET_PRODUCTION_BASE_URL" => nil, "BARISTA_WHITELIST" => "111, 222", "ORDER_EXPIRE_MINUTES" => "20"
    }
  end

  def in_shop(tenant = shop, &block) = ActsAsTenant.with_tenant(tenant, &block)

  # BotRegistration (bot agent) talks to Telegram: replaced by a fake that stores the bot
  def stub_bot_registration(error: nil)
    registrations = []
    registration_class = class_double("BotRegistration").as_stubbed_const
    allow(registration_class).to receive(:new) do |tenant:, token:|
      registrations << { tenant: tenant, token: token }
      double("BotRegistration").tap do |registration|
        allow(registration).to receive(:call) do
          raise error if error

          Bot.create!(tenant: tenant, token: token, username: "#{tenant.slug}_bot", telegram_bot_id: token.to_i)
        end
      end
    end
    registrations
  end

  describe "tenants:create" do
    it "creates a coffee shop" do
      result = run_task("tenants:create", "downtown", "Downtown Coffee")

      expect(result).to be_success
      expect(result.stdout).to match(/downtown: created/)
      expect(Tenant.find_by(slug: "downtown")).to have_attributes(name: "Downtown Coffee", status: "active")
    end

    it "is idempotent and renames an existing shop" do
      run_task("tenants:create", "downtown", "Downtown Coffee")

      expect(run_task("tenants:create", "downtown", "Downtown Coffee").stdout).to match(/already exists/)
      expect(run_task("tenants:create", "downtown", "Downtown Espresso").stdout).to match(/name updated/)
      expect(Tenant.where(slug: "downtown").pluck(:name)).to eq([ "Downtown Espresso" ])
    end

    it "needs a name for a new shop and a valid slug" do
      expect(run_task("tenants:create", "downtown")).to have_attributes(exit_status: 1, stderr: /name is required/)
      expect(run_task("tenants:create", "Down Town", "X").stderr).to match(/lowercase latin letters/)
      expect(run_task("tenants:create").stderr).to match(/usage/)
      expect(Tenant.where(slug: "downtown")).to be_empty
    end
  end

  describe "tenants:list" do
    it "shows every shop with masked credentials, staff and open orders" do
      ActsAsTenant.without_tenant do
        Bot.create!(tenant: shop, token: bot_token, username: "corner_bot", telegram_bot_id: 777)
        PaymentAccount.create!(tenant: shop, sid: "20250042", password: mwallet_password, base_url: PaymentAccount::TEST_BASE_URL)
      end
      in_shop do
        StaffMember.create!(telegram_user_id: 1, role: "owner")
        StaffMember.create!(telegram_user_id: 2, active: false)
        make_order(status: OrderStatus::PAID, invoice: "INV-A")
        make_order(status: OrderStatus::READY, invoice: "INV-B", user_id: TenancyHelpers::STRANGER_ID)
      end

      result = run_task("tenants:list")

      expect(result).to be_success
      expect(result.stdout.lines.first).to match(/\AID\s+SLUG\s+NAME\s+STATUS\s+BOT\s+MWALLET SID\s+STAFF\s+OPEN ORDERS/)
      row = result.stdout.lines.find { |line| line.include?("corner") }
      expect(row).to match(/Corner Coffee\s+active\s+@corner_bot\s+\*\*\*42 \(test\)\s+1\s+1$/)
      expect(result.stdout).to include(current_tenant.slug)
      expect(result.output).not_to include("20250042", mwallet_password, bot_token)
    end
  end

  describe "tenants:connect_bot" do
    it "registers the bot through BotRegistration without printing the token" do
      registrations = stub_bot_registration

      result = run_task("tenants:connect_bot", shop.slug, bot_token)

      expect(result).to be_success
      expect(registrations).to eq([ { tenant: shop, token: bot_token } ])
      expect(shop.bot.username).to eq("corner_bot")
      expect(result.stdout).to include("bot @corner_bot connected", "/tg/#{shop.bot.id}")
      expect(result.output).not_to include(bot_token)
    end

    it "reports a failed registration with the token filtered out" do
      stub_bot_registration(error: StandardError.new("Telegram said no to #{bot_token}"))

      result = run_task("tenants:connect_bot", shop.slug, bot_token)

      expect(result.exit_status).to eq(1)
      expect(result.stderr).to include("bot not connected", "[FILTERED]")
      expect(result.output).not_to include(bot_token)
    end

    it "fails for an unknown shop or a missing token" do
      registrations = stub_bot_registration

      expect(run_task("tenants:connect_bot", "nope", bot_token).stderr).to match(/"nope" not found/)
      expect(run_task("tenants:connect_bot", shop.slug).stderr).to match(/token is required/)
      expect(registrations).to be_empty
    end
  end

  describe "tenants:connect_mwallet" do
    def accounts = shop.payment_accounts.order(:id)

    it "creates the active test account without printing the password" do
      result = run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "true")

      expect(result).to be_success
      expect(shop.payment_account).to have_attributes(sid: "20250042", password: mwallet_password, test_mode: true,
                                                      base_url: PaymentAccount::TEST_BASE_URL, active: true)
      expect(result.stdout).to include("***42 created (test mode", "/pay/mwallet/#{shop.payment_account.id}")
      expect(result.output).not_to include(mwallet_password, "20250042")
    end

    it "updates the same account when run again" do
      run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "true")

      expect(run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "true").stdout).to include("unchanged")
      expect(run_task("tenants:connect_mwallet", shop.slug, "20250042", "new-password", "true").stdout).to include("updated")
      expect(accounts.map { |a| [ a.password, a.active ] }).to eq([ [ "new-password", true ] ])
    end

    it "deactivates the previous account when the SID changes" do
      run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "true")

      result = run_task("tenants:connect_mwallet", shop.slug, "20250099", mwallet_password, "true")

      expect(result.stdout).to include("1 previous MWallet account(s) deactivated")
      expect(accounts.map { |a| [ a.sid, a.active ] }).to eq([ [ "20250042", false ], [ "20250099", true ] ])
      expect(shop.payment_account.sid).to eq("20250099")
    end

    it "uses MWALLET_PRODUCTION_BASE_URL for live payments" do
      result = with_env("MWALLET_PRODUCTION_BASE_URL" => production_url) do
        run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "false")
      end

      expect(result).to be_success
      expect(shop.payment_account).to have_attributes(test_mode: false, base_url: production_url)
    end

    it "refuses live payments until the production URL is configured" do
      result = with_env("MWALLET_PRODUCTION_BASE_URL" => nil) do
        run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "false")
      end

      expect(result.exit_status).to eq(1)
      expect(result.stderr).to match(/MWALLET_PRODUCTION_BASE_URL is not set/)
      expect(accounts).to be_empty
    end

    it "rejects missing credentials and an unknown test_mode" do
      expect(run_task("tenants:connect_mwallet", shop.slug, "20250042").stderr).to match(/SID and password are required/)
      expect(run_task("tenants:connect_mwallet", shop.slug, "20250042", mwallet_password, "maybe").stderr)
        .to match(/test_mode must be true/)
      expect(accounts).to be_empty
    end
  end

  describe "tenants:add_staff and tenants:remove_staff" do
    def staff = in_shop { StaffMember.order(:telegram_user_id).map { |m| [ m.telegram_user_id, m.role, m.active ] } }

    it "adds, updates and removes staff idempotently" do
      expect(run_task("tenants:add_staff", shop.slug, "555").stdout).to include("staff 555 (barista) added")
      expect(run_task("tenants:add_staff", shop.slug, "555").stdout).to include("unchanged")
      expect(run_task("tenants:add_staff", shop.slug, "555", "owner").stdout).to include("(owner) updated")
      expect(run_task("tenants:add_staff", shop.slug, "555").stdout).to include("(owner) unchanged")

      expect(run_task("tenants:remove_staff", shop.slug, "555").stdout).to include("staff 555 removed")
      expect(run_task("tenants:remove_staff", shop.slug, "555").stdout).to include("already removed")
      expect(run_task("tenants:remove_staff", shop.slug, "999").stdout).to include("not a staff member")
      expect(staff).to eq([ [ 555, "owner", false ] ])

      expect(run_task("tenants:add_staff", shop.slug, "555").stdout).to include("updated")
      expect(staff).to eq([ [ 555, "owner", true ] ])
    end

    it "keeps staff of different shops apart" do
      run_task("tenants:add_staff", shop.slug, TenancyHelpers::BARISTA_ID.to_s)

      expect(staff).to eq([ [ TenancyHelpers::BARISTA_ID, "barista", true ] ])
      expect(current_tenant.staff_members.count).to eq(1)
    end

    it "validates the Telegram id and the role" do
      expect(run_task("tenants:add_staff", shop.slug, "@barista").stderr).to match(/positive number/)
      expect(run_task("tenants:add_staff", shop.slug, "-5").stderr).to match(/positive number/)
      expect(run_task("tenants:add_staff", shop.slug, "555", "admin").stderr).to match(/owner, manager, barista/)
      expect(staff).to be_empty
    end
  end

  describe "tenants:seed_menu" do
    it "seeds the menu through MenuService" do
      menu_service = class_double("MenuService").as_stubbed_const
      allow(menu_service).to receive(:seed_menu).with(shop) do
        in_shop { MenuItem.create!(category: "Кофе", name: "Латте", price: 15_000) }
        1
      end

      expect(run_task("tenants:seed_menu", shop.slug).stdout).to include("1 menu items created (1 in the menu)")

      allow(menu_service).to receive(:seed_menu).with(shop).and_return(0)
      expect(run_task("tenants:seed_menu", shop.slug).stdout).to include("menu already has 1 items")
    end
  end

  describe "tenants:import_legacy_env" do
    def import(env = legacy_env) = with_env(env) { run_task("tenants:import_legacy_env", "main", "Main Coffee") }

    def imported = Tenant.find_by!(slug: "main")

    it "turns the single-shop .env into the first tenant" do
      registrations = stub_bot_registration

      result = import

      expect(result).to be_success
      expect(imported).to have_attributes(name: "Main Coffee", order_expire_minutes: 20)
      expect(imported.payment_account).to have_attributes(sid: "20250042", password: mwallet_password, test_mode: true,
                                                          base_url: PaymentAccount::TEST_BASE_URL)
      expect(in_shop(imported) { StaffMember.active.order(:telegram_user_id).pluck(:telegram_user_id, :role) })
        .to eq([ [ 111, "barista" ], [ 222, "barista" ] ])
      expect(registrations).to eq([ { tenant: imported, token: bot_token } ])
      expect(imported.bot.username).to eq("main_bot")
      expect(result.output).not_to include(bot_token, mwallet_password, "20250042")
    end

    it "can be run again without registering the bot twice or downgrading staff" do
      registrations = stub_bot_registration
      import
      run_task("tenants:add_staff", "main", "111", "owner")

      result = import

      expect(result).to be_success
      expect(result.stdout).to include("bot @main_bot already connected", "MWallet account ***42 unchanged")
      expect(registrations.size).to eq(1)
      expect(imported.payment_accounts.count).to eq(1)
      expect(in_shop(imported) { StaffMember.order(:telegram_user_id).pluck(:role) }).to eq(%w[owner barista])
    end

    it "skips what is not configured" do
      registrations = stub_bot_registration
      env = legacy_env.merge("TELEGRAM_BOT_TOKEN" => nil, "MWALLET_SID" => nil, "BARISTA_WHITELIST" => "",
                             "ORDER_EXPIRE_MINUTES" => nil)

      result = import(env)

      expect(result).to be_success
      expect(result.stdout).to include("TELEGRAM_BOT_TOKEN not set", "MWALLET_SID / MWALLET_PASSWORD not set",
                                       "BARISTA_WHITELIST not set")
      expect(registrations).to be_empty
      expect(imported).to have_attributes(bot: nil, payment_account: nil, order_expire_minutes: 15)
    end

    it "imports a live account with the legacy MWALLET_BASE_URL as the production URL" do
      stub_bot_registration

      import(legacy_env.merge("MWALLET_TEST_MODE" => "false", "MWALLET_BASE_URL" => production_url,
                              "MWALLET_API_VERSION" => "1006"))

      expect(imported.payment_account).to have_attributes(test_mode: false, base_url: production_url, api_version: 1006)
    end

    it "stops on invalid values before connecting the bot" do
      registrations = stub_bot_registration

      result = import(legacy_env.merge("ORDER_EXPIRE_MINUTES" => "soon"))

      expect(result.exit_status).to eq(1)
      expect(result.stderr).to match(/ORDER_EXPIRE_MINUTES must be a whole number/)
      expect(registrations).to be_empty
    end
  end

  # A real rake run has no current tenant and acts_as_tenant requires one for scoped models
  it "runs the whole onboarding without a current tenant" do
    registrations = stub_bot_registration
    menu_service = class_double("MenuService", seed_menu: 0).as_stubbed_const

    results = without_current_tenant do
      [
        run_task("tenants:create", "fresh", "Fresh Coffee"),
        run_task("tenants:connect_mwallet", "fresh", "20250042", mwallet_password, "test"),
        run_task("tenants:add_staff", "fresh", "555", "owner"),
        run_task("tenants:remove_staff", "fresh", "555"),
        run_task("tenants:seed_menu", "fresh"),
        run_task("tenants:connect_bot", "fresh", bot_token),
        run_task("tenants:list"),
        with_env(legacy_env) { run_task("tenants:import_legacy_env", "fresh") }
      ]
    end

    expect(results.map(&:stderr)).to all(be_empty)
    expect(results).to all(be_success)
    expect(registrations.size).to eq(1) # the import sees the bot of the same token already connected
    expect(menu_service).to have_received(:seed_menu).once
    expect(results[6].stdout).to match(/fresh\s+Fresh Coffee\s+active\s+@fresh_bot/)
  end
end
