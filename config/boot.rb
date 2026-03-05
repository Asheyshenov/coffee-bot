# frozen_string_literal: true

# Boot file - loads environment, logger, and database
# This file is required by bin/bot and bin/callback_app

require 'dotenv/load'
require 'logger'
require 'json'

# Configure logger with JSON format for production
class JsonFormatter < Logger::Formatter
  def call(severity, datetime, _progname, message)
    log_entry = {
      timestamp: datetime.utc.iso8601(3),
      level: severity,
      message: message.is_a?(String) ? message : message.to_json
    }
    "#{log_entry.to_json}\n"
  end
end

# Create application logger
module CoffeeBot
  # rubocop:disable Style/MutableConstant
  LOG = Logger.new($stdout)
  
  # Use JSON format in production, plain text in development
  if ENV['RACK_ENV'] == 'production'
    LOG.formatter = JsonFormatter.new
  else
    LOG.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.utc.iso8601(3)}] #{severity}: #{msg}\n"
    end
  end
  # rubocop:enable Style/MutableConstant

  # Configuration constants from environment
  module Config
    # Telegram
    TELEGRAM_BOT_TOKEN = ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
    
    # Database
    DATABASE_URL = ENV.fetch('DATABASE_URL', 'sqlite://db/development.sqlite3')
    
    # Barista access control - comma-separated telegram user IDs
    BARISTA_WHITELIST = ENV.fetch('BARISTA_WHITELIST', '')
                          .split(',')
                          .map(&:strip)
                          .reject(&:empty?)
                          .map(&:to_i)
    
    # Order settings
    ORDER_EXPIRE_MINUTES = ENV.fetch('ORDER_EXPIRE_MINUTES', 15).to_i
    
    # QRPay / O!Деньги configuration (legacy)
    QRPAY_BASE_URL = ENV.fetch('QRPAY_BASE_URL', 'https://api.odengi.kg')
    QRPAY_MERCHANT_ID = ENV.fetch('QRPAY_MERCHANT_ID', nil)
    QRPAY_SECRET_KEY = ENV.fetch('QRPAY_SECRET_KEY', nil)
    
    # Public URL for callbacks
    PUBLIC_BASE_URL = ENV.fetch('PUBLIC_BASE_URL', 'http://localhost:9292')
    QRPAY_CALLBACK_URL = "#{PUBLIC_BASE_URL}/callbacks/odengi/qrpay/result"
    
    # QRPay timeouts
    QRPAY_TIMEOUT_SECONDS = ENV.fetch('QRPAY_TIMEOUT_SECONDS', 30).to_i
    QRPAY_RETRY_COUNT = ENV.fetch('QRPAY_RETRY_COUNT', 3).to_i
    
    # MWallet API configuration
    MWALLET_BASE_URL = ENV.fetch('MWALLET_BASE_URL', 'https://mw-api-test.dengi.kg/api/json/json.php')
    MWALLET_SID = ENV.fetch('MWALLET_SID', nil)
    MWALLET_PASSWORD = ENV.fetch('MWALLET_PASSWORD', nil)
    MWALLET_API_VERSION = ENV.fetch('MWALLET_API_VERSION', 1005).to_i
    MWALLET_TEST_MODE = ENV.fetch('MWALLET_TEST_MODE', 'true').downcase == 'true'
    
    # MWallet callback URL
    MWALLET_CALLBACK_URL = "#{PUBLIC_BASE_URL}/callbacks/mwallet/result"
    
    # MWallet timeouts
    MWALLET_TIMEOUT_SECONDS = ENV.fetch('MWALLET_TIMEOUT_SECONDS', 30).to_i
    MWALLET_RETRY_COUNT = ENV.fetch('MWALLET_RETRY_COUNT', 3).to_i
    
    # Environment
    RACK_ENV = ENV.fetch('RACK_ENV', 'development')
  end
end

# Helper method for logging with context
def log_info(message, context = {})
  msg = context.empty? ? message : { message: message, **context }
  CoffeeBot::LOG.info(msg)
end

def log_error(message, context = {})
  msg = context.empty? ? message : { message: message, **context }
  CoffeeBot::LOG.error(msg)
end

def log_debug(message, context = {})
  msg = context.empty? ? message : { message: message, **context }
  CoffeeBot::LOG.debug(msg)
end

# Load database connection
require_relative 'database'
