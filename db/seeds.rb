# frozen_string_literal: true

# Development demo data: one coffee shop with FAKE credentials and a menu.
# Idempotent (bin/rails db:seed can be re-run). Never put real tokens or passwords here:
# real coffee shops are onboarded with the tenants:* rake tasks (see README).
#
# db:prepare also runs seeds when it creates a database, including in production,
# hence the environment guard.
unless Rails.env.development?
  puts "Seeds: skipped in #{Rails.env} (demo data is for development only)"
  return
end

ActsAsTenant.without_tenant do
  tenant = Tenant.find_or_create_by!(slug: "demo") { |t| t.name = "Demo Coffee" }

  # The token is not a real bot: Telegram API calls with it fail with 401
  tenant.bot || Bot.create!(tenant: tenant, telegram_bot_id: 100_000_001, username: "demo_coffee_bot",
                            token: "100000001:DEMO-FAKE-TOKEN-not-a-real-bot")

  tenant.payment_account || PaymentAccount.create!(tenant: tenant, sid: "demo-sid", password: "demo-password",
                                                   base_url: PaymentAccount::TEST_BASE_URL, test_mode: true)

  ActsAsTenant.with_tenant(tenant) do
    StaffMember.find_or_create_by!(telegram_user_id: 100_000_002) { |m| m.assign_attributes(role: "owner", name: "Demo Owner") }

    if defined?(MenuService)
      MenuService.seed_menu(tenant)
    elsif MenuItem.none?
      [
        { category: "Кофе", name: "Эспрессо", price: 12_000 },
        { category: "Кофе", name: "Латте", price: 15_000, sizes: { "small" => 15_000, "large" => 19_000 }, default_size: "small" },
        { category: "Десерты", name: "Круассан", price: 9_000 }
      ].each_with_index { |attrs, position| MenuItem.create!(attrs.merge(position: position)) }
    end

    puts "Seeds: tenant #{tenant.slug} (id #{tenant.id}), #{MenuItem.count} menu items, #{StaffMember.count} staff"
  end
end
