# frozen_string_literal: true

source 'https://rubygems.org'

# Telegram Bot API
gem 'telegram-bot-ruby', '2.4.0'

# Database
gem 'sequel'
gem 'sqlite3' # Development only - switch to pg for production

# Configuration
gem 'dotenv'

# HTTP Client for QRPay API
gem 'faraday'
gem 'faraday-multipart'

# HTTP Server for callbacks
gem 'sinatra'
gem 'puma'
gem 'rackup'

# JSON handling
gem 'json'

# Logging
gem 'logger'

# Testing
group :development, :test do
  gem 'rspec'
  gem 'rack-test'
  gem 'database_cleaner-sequel'
end

# Development tools
group :development do
  gem 'pry'
  gem 'rubocop', require: false
end
