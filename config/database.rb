# frozen_string_literal: true

# Database configuration using Sequel ORM
# Supports both SQLite (development) and PostgreSQL (production)

require 'sequel'

module CoffeeBot
  # Database connection singleton
  class DB
    class << self
      attr_reader :connection

      # Initialize database connection
      # This is called automatically when this file is required
      def connect
        database_url = Config::DATABASE_URL
        
        log_info('Connecting to database', url: mask_password(database_url))
        
        @connection = Sequel.connect(database_url)
        
        # Configure Sequel settings
        configure_sequel
        
        # Run migrations in development if needed
        run_migrations_if_needed
        
        @connection
      end
      
      # Run migrations (for test environment)
      def run_migrations!
        migrations_dir = File.expand_path('../db/migrations', __dir__)
        return unless Dir.exist?(migrations_dir)
        
        require 'sequel/extensions/migration'
        Sequel.extension :migration
        
        Sequel::Migrator.run(@connection, migrations_dir, use_transactions: true)
      end

      private

      def configure_sequel
        # Use UTC timezone for datetime columns
        Sequel.default_timezone = :utc
        
        # Enable plugins for all models
        Sequel::Model.plugin :timestamps, update_on_create: true
        Sequel::Model.plugin :validation_helpers
        
        # Log SQL queries in development
        if Config::RACK_ENV == 'development'
          @connection.loggers << Logger.new($stdout, level: Logger::DEBUG)
        end
        
        # Raise errors on save failures
        Sequel::Model.raise_on_save_failure = false
      end

      def run_migrations_if_needed
        return unless Config::RACK_ENV == 'development'
        
        migrations_dir = File.expand_path('../db/migrations', __dir__)
        return unless Dir.exist?(migrations_dir)
        
        require 'sequel/extensions/migration'
        Sequel.extension :migration
        
        log_info('Running database migrations...')
        
        Sequel::Migrator.run(@connection, migrations_dir, use_transactions: true)
        
        log_info('Migrations completed successfully')
      rescue Sequel::Migrator::Error => e
        log_error('Migration error', error: e.message)
        # Don't fail startup - migrations might not exist yet
      end

      def mask_password(url)
        url.to_s.gsub(/\/\/([^:]+):([^@]+)@/, '//\1:****@')
      end
    end
  end
end

# Connect to database when this file is loaded
CoffeeBot::DB.connect

# Convenience accessor
DB = CoffeeBot::DB.connection
