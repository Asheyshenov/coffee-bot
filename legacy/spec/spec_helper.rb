# frozen_string_literal: true

# RSpec Configuration

require 'bundler/setup'
require 'rack/test'

# Set test environment
ENV['RACK_ENV'] = 'test'
ENV['DATABASE_URL'] = 'sqlite::memory:'

require_relative '../config/boot'

# Load Sequel migration extension
Sequel.extension :migration

# Run migrations BEFORE loading models
CoffeeBot::DB.run_migrations!

# Load all models
Dir[File.expand_path('../lib/models/*.rb', __dir__)].sort.each { |f| require f }
Dir[File.expand_path('../lib/services/**/*.rb', __dir__)].sort.each { |f| require f }

# Configure DatabaseCleaner
require 'database_cleaner/sequel'

DatabaseCleaner.strategy = :transaction

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end

  # Include test helpers
  config.include Rack::Test::Methods, type: :request
end

# Test helpers
module TestHelpers
  def create_test_client(telegram_id: 123_456_789, username: 'test_user')
    Client.create(
      telegram_user_id: telegram_id,
      username: username,
      first_name: 'Test',
      last_name: 'User'
    )
  end

  def create_test_menu_item(category: 'Кофе', name: 'Тест', price: 10_000, sizes: nil, default_size: 'medium')
    MenuItem.create(
      category: category,
      name: name,
      price: price,
      currency: 'KGS',
      is_available: true,
      sizes: sizes,
      default_size: default_size
    )
  end

  def create_test_order(client, amount: 10_000)
    Order.create(
      telegram_user_id: client.telegram_user_id,
      client_display_name: client.display_name,
      status: OrderStatus::NEW,
      total_amount: amount,
      currency: 'KGS',
      merchant_invoice_id: "ORDER-TEST-#{Time.now.to_i}"
    )
  end

  def create_test_draft(telegram_user_id)
    Draft.create(
      telegram_user_id: telegram_user_id,
      state_json: {
        'step' => 'select_category',
        'items' => [],
        'comment' => nil
      }.to_json
    )
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
