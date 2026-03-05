# frozen_string_literal: true

# Auth Service
# Handles authentication and authorization for barista access

require_relative '../../config/boot'

module CoffeeBot
  module Services
    class AuthService
      # Check if telegram user is an authorized barista
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Boolean] True if user is authorized
      def self.barista?(telegram_user_id)
        whitelist = CoffeeBot::Config::BARISTA_WHITELIST
        return false if whitelist.empty?
        
        whitelist.include?(telegram_user_id)
      end

      # Check if barista whitelist is configured
      #
      # @return [Boolean] True if whitelist is not empty
      def self.barista_configured?
        !CoffeeBot::Config::BARISTA_WHITELIST.empty?
      end

      # Get all authorized barista IDs
      #
      # @return [Array<Integer>] List of barista telegram IDs
      def self.all_baristas
        CoffeeBot::Config::BARISTA_WHITELIST
      end

      # Validate barista access and raise error if not authorized
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @raise [UnauthorizedError] If user is not authorized
      def self.require_barista!(telegram_user_id)
        unless barista?(telegram_user_id)
          raise UnauthorizedError, "User #{telegram_user_id} is not authorized as barista"
        end
        true
      end

      # Check if user can access specific order
      # Baristas can only access orders assigned to them or unassigned
      #
      # @param order [Order] The order to check
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Boolean] True if user can access
      def self.can_access_order?(order, telegram_user_id)
        return true unless barista?(telegram_user_id)
        
        # Barista can access if order is assigned to them or unassigned
        order.assigned_to_barista_id.nil? || 
          order.assigned_to_barista_id == telegram_user_id
      end
    end
  end
end

# Custom error for unauthorized access
class UnauthorizedError < StandardError; end
