# frozen_string_literal: true

# Onboarding of coffee shops from the command line (until the admin panel exists).
#
#   bin/rails "tenants:create[corner,Corner Coffee]"
#   bin/rails "tenants:connect_mwallet[corner,SID,PASSWORD,true]"
#   bin/rails "tenants:add_staff[corner,123456789,owner]"
#   bin/rails "tenants:seed_menu[corner]"
#   bin/rails "tenants:connect_bot[corner,123456:ABC-DEF]"
#   bin/rails "tenants:refresh_bot[corner]"
#   bin/rails tenants:list
#
# Every task can be re-run safely and never prints bot tokens or MWallet passwords.
# acts_as_tenant requires a tenant for scoped models: tenant data is touched only
# inside ActsAsTenant.with_tenant(tenant), cross-tenant reads inside without_tenant.
module TenantTasks
  class Error < StandardError; end

  TEST_MODE_VALUES = { true => %w[true 1 yes test], false => %w[false 0 no production live] }.freeze
  LIST_HEADERS = [ "ID", "SLUG", "NAME", "STATUS", "BOT", "MWALLET SID", "STAFF", "OPEN ORDERS" ].freeze

  module_function

  # Runs a task body: expected failures become one readable line on stderr and exit code 1
  def run
    I18n.with_locale(:en) { yield }
  rescue Error, ActiveRecord::RecordInvalid => e
    abort "Error: #{e.message}"
  rescue ActiveRecord::Encryption::Errors::Configuration
    abort "Error: Active Record encryption keys are missing. Set ACTIVE_RECORD_ENCRYPTION_* (see .env.example)"
  end

  def find_tenant!(slug)
    raise Error, "tenant slug is required" if slug.blank?

    Tenant.find_by(slug: slug.strip) || raise(Error, "tenant #{slug.strip.inspect} not found (see bin/rails tenants:list)")
  end

  # Creates the tenant, or renames an existing one when a different name is given
  def create_tenant(slug, name)
    raise Error, "usage: bin/rails \"tenants:create[slug,Name]\"" if slug.blank?

    tenant = Tenant.find_or_initialize_by(slug: slug.strip)
    if tenant.new_record?
      raise Error, "name is required to create tenant #{slug.strip.inspect}" if name.blank?

      tenant.name = name.strip
      if tenant.invalid? && tenant.errors.include?(:slug)
        raise Error, "slug may contain only lowercase latin letters, digits and dashes (e.g. corner-coffee)"
      end
      tenant.save!
      say tenant, "created (id #{tenant.id})"
    elsif name.present? && tenant.name != name.strip
      tenant.update!(name: name.strip)
      say tenant, "already exists, name updated"
    else
      say tenant, "already exists (id #{tenant.id})"
    end
    tenant
  end

  def list
    rows = ActsAsTenant.without_tenant do
      staff = StaffMember.active.group(:tenant_id).count
      open_orders = Order.where(status: OrderStatus::ACTIVE).group(:tenant_id).count
      bots = Bot.where(active: true).select(:tenant_id, :username).index_by(&:tenant_id)
      accounts = PaymentAccount.where(active: true).select(:tenant_id, :sid, :test_mode).index_by(&:tenant_id)

      Tenant.order(:id).map do |tenant|
        bot = bots[tenant.id]
        account = accounts[tenant.id]
        [ tenant.id, tenant.slug, tenant.name, tenant.status,
          bot ? "@#{bot.username}" : "-",
          account ? "#{mask(account.sid)} (#{account.test_mode ? 'test' : 'live'})" : "-",
          staff.fetch(tenant.id, 0), open_orders.fetch(tenant.id, 0) ]
      end
    end

    return puts("No tenants yet: bin/rails \"tenants:create[slug,Name]\"") if rows.empty?

    print_table(LIST_HEADERS, rows)
  end

  # BotRegistration checks the token (getMe), stores the bot and sets its webhook
  def connect_bot(tenant, token)
    token = token.to_s.strip
    raise Error, "bot token is required (from @BotFather)" if token.empty?

    bot = ActsAsTenant.with_tenant(tenant) { BotRegistration.new(tenant: tenant, token: token).call }
    say tenant, "bot @#{bot.username} connected, webhook #{bot.webhook_url}"
    bot
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "bot not connected: #{redact(e.message, token)} (#{e.class})"
  end

  # Sets the webhook, command menu and Mini App menu button of the connected bot again,
  # without a new token: after PUBLIC_BASE_URL changed, or for bots connected before the Mini App
  def refresh_bot(tenant)
    bot = tenant.bot
    raise Error, "no bot connected (bin/rails \"tenants:connect_bot[#{tenant.slug},TOKEN]\")" unless bot

    token = bot.token
    result = ActsAsTenant.with_tenant(tenant) { BotRegistration.refresh(bot) }
    say tenant, "bot @#{bot.username} refreshed, webhook #{bot.webhook_url}"
    say tenant, result[:commands] ? "command menu set" : "command menu NOT set (Telegram error, see the log)"
    say tenant, menu_button_status(bot, result[:menu_button])
    bot
  rescue Error, ActiveRecord::Encryption::Errors::Configuration
    raise
  rescue StandardError => e
    raise Error, "bot not refreshed: #{redact(e.message, token)} (#{e.class})"
  end

  def menu_button_status(bot, status)
    case status
    when true then "Mini App menu button set, #{bot.mini_app_url}"
    when :skipped then "Mini App menu button skipped: PUBLIC_BASE_URL must be https:// (Telegram opens Mini Apps only over HTTPS)"
    else "Mini App menu button NOT set (Telegram error, see the log)"
    end
  end

  # Makes the account with this SID the tenant's only active MWallet account.
  # Older accounts are deactivated, not deleted: their orders and callback URLs keep working.
  def connect_mwallet(tenant, sid, password, test_mode, base_url: nil, api_version: nil)
    sid = sid.to_s.strip
    raise Error, "MWallet SID and password are required" if sid.empty? || password.blank?

    test_mode = parse_test_mode(test_mode)
    base_url ||= mwallet_base_url(test_mode)

    account = tenant.payment_accounts.find_or_initialize_by(provider: "mwallet", sid: sid)
    state = account.new_record? ? "created" : "updated"
    deactivated = 0
    PaymentAccount.transaction do
      deactivated = tenant.payment_accounts.where(active: true).where.not(id: account.id)
                          .update_all(active: false, updated_at: Time.current)
      account.assign_attributes(password: password, base_url: base_url, test_mode: test_mode, active: true)
      account.api_version = api_version if api_version
      state = "unchanged" if account.persisted? && !account.changed?
      account.save!
    end

    say tenant, "MWallet account #{mask(sid)} #{state} (#{test_mode ? 'test' : 'live'} mode, #{base_url})"
    say tenant, "#{deactivated} previous MWallet account(s) deactivated" if deactivated.positive?
    say tenant, "payment callback URL #{account.callback_url}"
    account
  end

  # Adds or re-activates a staff member. Without a role an existing member keeps theirs.
  def add_staff(tenant, telegram_user_id, role = nil)
    user_id = parse_telegram_id(telegram_user_id)
    role = role.to_s.strip.presence
    raise Error, "role must be one of: #{StaffMember::ROLES.join(', ')}" if role && !StaffMember::ROLES.include?(role)

    ActsAsTenant.with_tenant(tenant) do
      member = StaffMember.find_or_initialize_by(telegram_user_id: user_id)
      state = member.new_record? ? "added" : "updated"
      member.assign_attributes(role: role || member.role, active: true)
      state = "unchanged" if member.persisted? && !member.changed?
      member.save!
      say tenant, "staff #{user_id} (#{member.role}) #{state}"
      member
    end
  end

  # Deactivates a staff member (the record stays, add_staff brings them back)
  def remove_staff(tenant, telegram_user_id)
    user_id = parse_telegram_id(telegram_user_id)

    ActsAsTenant.with_tenant(tenant) do
      member = StaffMember.find_by(telegram_user_id: user_id)
      if member.nil?
        say tenant, "#{user_id} is not a staff member, nothing to do"
      elsif !member.active?
        say tenant, "staff #{user_id} already removed"
      else
        member.update!(active: false)
        say tenant, "staff #{user_id} removed"
      end
    end
  end

  def seed_menu(tenant)
    raise Error, "MenuService is not available" unless defined?(MenuService)

    created = MenuService.seed_menu(tenant).to_i
    total = ActsAsTenant.with_tenant(tenant) { MenuItem.count }
    if created.positive?
      say tenant, "#{created} menu items created (#{total} in the menu)"
    else
      say tenant, "menu already has #{total} items, nothing seeded"
    end
  end

  # Makes the single coffee shop of the old app (configured through ENV) a tenant.
  # The bot goes last: once its webhook is set, customers reach the new app.
  def import_legacy_env(slug, name)
    tenant = create_tenant(slug, name)
    import_order_expiry(tenant)
    import_mwallet(tenant)
    import_baristas(tenant)
    import_bot(tenant)
    say tenant, "legacy import done. TELEGRAM_BOT_TOKEN, MWALLET_*, BARISTA_WHITELIST and " \
                "ORDER_EXPIRE_MINUTES are not read by the app: remove them from .env"
    tenant
  end

  def import_order_expiry(tenant)
    minutes = parse_integer(ENV["ORDER_EXPIRE_MINUTES"], "ORDER_EXPIRE_MINUTES")
    return unless minutes

    tenant.update!(order_expire_minutes: minutes)
    say tenant, "invoices expire after #{minutes} minutes"
  end

  def import_mwallet(tenant)
    sid = ENV["MWALLET_SID"].to_s.strip
    password = ENV["MWALLET_PASSWORD"].to_s
    return say(tenant, "MWALLET_SID / MWALLET_PASSWORD not set, payment account skipped") if sid.empty? || password.empty?

    test_mode = parse_test_mode(ENV.fetch("MWALLET_TEST_MODE", "true"))
    # A live legacy setup already talks to the production API: its MWALLET_BASE_URL is the fallback
    base_url = mwallet_base_url(test_mode, fallback: ENV["MWALLET_BASE_URL"])
    api_version = parse_integer(ENV["MWALLET_API_VERSION"], "MWALLET_API_VERSION")
    connect_mwallet(tenant, sid, password, test_mode, base_url: base_url, api_version: api_version)
  end

  def import_baristas(tenant)
    ids = ENV["BARISTA_WHITELIST"].to_s.split(",").map(&:strip).reject(&:empty?)
    return say(tenant, "BARISTA_WHITELIST not set, no staff imported") if ids.empty?

    ids.each { |id| add_staff(tenant, id) }
  end

  def import_bot(tenant)
    token = ENV["TELEGRAM_BOT_TOKEN"].to_s.strip
    return say(tenant, "TELEGRAM_BOT_TOKEN not set, bot skipped") if token.empty?

    current = tenant.bot
    if current&.token == token
      say tenant, "bot @#{current.username} already connected (run tenants:connect_bot to register it again)"
    else
      connect_bot(tenant, token)
    end
  end

  def mwallet_base_url(test_mode, fallback: nil)
    return PaymentAccount::TEST_BASE_URL if test_mode

    url = ENV["MWALLET_PRODUCTION_BASE_URL"].presence || fallback.presence
    raise Error, "MWALLET_PRODUCTION_BASE_URL is not set (confirm the production API URL with O!Dengi)" unless url
    raise Error, "MWALLET_PRODUCTION_BASE_URL must be an https:// URL" unless url.start_with?("https://")
    raise Error, "MWALLET_PRODUCTION_BASE_URL points to the O!Dengi test API" if url == PaymentAccount::TEST_BASE_URL

    url
  end

  def parse_test_mode(value)
    return value if value == true || value == false

    value = value.to_s.strip.downcase
    return true if value.empty?

    TEST_MODE_VALUES.each { |mode, words| return mode if words.include?(value) }
    raise Error, "test_mode must be true (O!Dengi test API) or false (live payments)"
  end

  # nil when the value is blank
  def parse_integer(value, name)
    value = value.to_s.strip
    return if value.empty?

    Integer(value, 10)
  rescue ArgumentError
    raise Error, "#{name} must be a whole number"
  end

  def parse_telegram_id(value)
    id = Integer(value.to_s.strip, 10)
    raise ArgumentError unless id.positive?

    id
  rescue ArgumentError
    raise Error, "Telegram user id must be a positive number (ask the person to message @userinfobot)"
  end

  # "***34": enough to tell accounts apart without showing the credential
  def mask(value)
    value = value.to_s
    value.length > 4 ? "***#{value.last(2)}" : "****"
  end

  def redact(message, *secrets)
    secrets.compact_blank.reduce(message.to_s) { |text, secret| text.gsub(secret, "[FILTERED]") }
  end

  def say(tenant, message)
    puts "#{tenant.slug}: #{message}"
  end

  def print_table(headers, rows)
    table = [ headers, *rows ].map { |row| row.map(&:to_s) }
    widths = headers.each_index.map { |i| table.map { |row| row[i].length }.max }
    table.each { |row| puts row.each_with_index.map { |cell, i| cell.ljust(widths[i]) }.join("  ").rstrip }
  end
end

namespace :tenants do
  desc "List coffee shops with their bot, MWallet account, staff and open orders"
  task list: :environment do
    TenantTasks.run { TenantTasks.list }
  end

  desc "Create a coffee shop (or rename it)"
  task :create, %i[slug name] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.create_tenant(args[:slug], args[:name]) }
  end

  desc "Connect the shop's Telegram bot and set its webhook"
  task :connect_bot, %i[slug token] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.connect_bot(TenantTasks.find_tenant!(args[:slug]), args[:token]) }
  end

  desc "Set the webhook, command menu and Mini App menu button of the shop's connected bot again (no new token)"
  task :refresh_bot, %i[slug] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.refresh_bot(TenantTasks.find_tenant!(args[:slug])) }
  end

  desc "Set the shop's MWallet merchant account (test_mode: true = test API, false = live payments)"
  task :connect_mwallet, %i[slug sid password test_mode] => :environment do |_task, args|
    TenantTasks.run do
      tenant = TenantTasks.find_tenant!(args[:slug])
      TenantTasks.connect_mwallet(tenant, args[:sid], args[:password], args[:test_mode])
    end
  end

  desc "Add or re-activate a staff member (role: owner, manager or barista)"
  task :add_staff, %i[slug telegram_user_id role] => :environment do |_task, args|
    TenantTasks.run do
      # Without a role a new member becomes a barista and an existing one keeps their role
      TenantTasks.add_staff(TenantTasks.find_tenant!(args[:slug]), args[:telegram_user_id], args[:role])
    end
  end

  desc "Remove a staff member from the barista panel"
  task :remove_staff, %i[slug telegram_user_id] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.remove_staff(TenantTasks.find_tenant!(args[:slug]), args[:telegram_user_id]) }
  end

  desc "Fill an empty menu with the default coffee shop menu"
  task :seed_menu, %i[slug] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.seed_menu(TenantTasks.find_tenant!(args[:slug])) }
  end

  desc "Make the old single-shop setup from .env (TELEGRAM_BOT_TOKEN, MWALLET_*, BARISTA_WHITELIST) a tenant"
  task :import_legacy_env, %i[slug name] => :environment do |_task, args|
    TenantTasks.run { TenantTasks.import_legacy_env(args[:slug], args[:name]) }
  end
end
