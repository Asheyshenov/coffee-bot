# frozen_string_literal: true

# HTTP Callback Server
# Sinatra app for receiving payment callbacks from providers

require 'sinatra/base'
require 'json'
require 'telegram/bot'

module CoffeeBot
  module HTTP
    class CallbackApp < Sinatra::Base
      # Disable Sinatra logging (use our own)
      set :logging, false

      # Configure host authorization per environment
      # Prevents "Host not permitted" errors when using tunneling services
      configure :development do
        # Permit tunnel hosts for development callbacks
        # Example: TUNNEL_HOSTS=.trycloudflare.com,.ngrok-free.app
        tunnel_hosts = ENV.fetch('TUNNEL_HOSTS', '.trycloudflare.com').split(',').map(&:strip).reject(&:empty?)
        set :host_authorization, {
          permitted_hosts: ['localhost', '.localhost', '.test'] + tunnel_hosts
        }
      end

      configure :production do
        # In production, only permit configured public host
        require 'uri'
        public_host = begin
          URI.parse(CoffeeBot::Config::PUBLIC_BASE_URL).host
        rescue StandardError
          nil
        end
        set :host_authorization, {
          permitted_hosts: [public_host].compact
        }
      end

      # JSON content type for all responses
      before do
        content_type :json
      end

      # Health check endpoint
      get '/health' do
        {
          status: 'ok',
          timestamp: Time.now.utc.iso8601,
          environment: CoffeeBot::Config::RACK_ENV
        }.to_json
      end

      # MWallet callback endpoint
      # 200 - processed (or unknown order / duplicate, acknowledged)
      # 400 - empty or malformed body, 401 - bad signature
      post '/callbacks/mwallet/result' do
        request.body.rewind
        raw_body = request.body.read.to_s
        
        log_info('Received MWallet callback',
          content_type: request.content_type,
          body_length: raw_body.length
        )

        # Parse callback data (nil for empty / malformed / non-object bodies)
        params = parse_callback_data(raw_body, request.content_type)
        unless params
          log_error('Invalid MWallet callback body', body_length: raw_body.length)
          halt 400, { error: 'Invalid request body' }.to_json
        end

        begin
          # Process callback (signature verification inside service)
          result = Services::OrderService.process_payment_callback(params, raw_body)

          # Notify client + baristas (or alert baristas about a payment problem).
          # Only the caller that changed the order gets these flags.
          if result[:order_id] && (result[:notify_barista] || result[:payment_error] || result[:refund_required])
            notify_payment_async(result)
          end

          { status: 'ok' }.to_json

        rescue MWalletError::SignatureError => e
          log_error('MWallet callback signature verification failed', error: e.message)
          halt 401, { error: 'Invalid signature' }.to_json

        rescue MWalletError::ValidationError => e
          log_error('Invalid MWallet callback', error: e.message)
          halt 400, { error: 'Invalid request body' }.to_json

        rescue StandardError => e
          log_error('Callback processing error',
            error: "#{e.class}: #{e.message}",
            backtrace: e.backtrace&.first(3)
          )
          # Return 200 to acknowledge receipt; StatusSyncer polling is the fallback.
          # Never expose exception details to the caller.
          { status: 'error' }.to_json
        end
      end

      # QRPay callback endpoint (legacy)
      post '/callbacks/odengi/qrpay/result' do
        request.body.rewind
        raw_body = request.body.read
        
        log_info('Received QRPay callback (legacy)',
          content_type: request.content_type,
          body_length: raw_body.length
        )

        # QRPay is deprecated, return error
        halt 410, { error: 'QRPay integration deprecated' }.to_json
      end

      # Catch-all for undefined routes
      not_found do
        { error: 'Not found' }.to_json
      end

      # Error handler
      error do
        log_error('Server error', error: env['sinatra.error'].message)
        { error: 'Internal server error' }.to_json
      end

      private

      # Parse callback data based on content type
      # @return [Hash, nil] Params with string keys, nil if the body is empty or malformed
      def parse_callback_data(raw_body, content_type)
        return nil if raw_body.strip.empty?

        data = if content_type&.include?('application/json')
                 JSON.parse(raw_body)
               elsif content_type&.include?('application/x-www-form-urlencoded')
                 Rack::Utils.parse_nested_query(raw_body)
               else
                 # Try JSON first, then form data
                 begin
                   JSON.parse(raw_body)
                 rescue JSON::ParserError
                   Rack::Utils.parse_nested_query(raw_body)
                 end
               end

        data.is_a?(Hash) ? data.transform_keys(&:to_s) : nil
      rescue JSON::ParserError, Rack::Utils::ParameterTypeError, Rack::Utils::InvalidParameterError,
             Rack::QueryParser::QueryLimitError
        nil
      end

      # Send payment notifications asynchronously (client + baristas, or a payment
      # problem alert). Runs in a separate thread to not block the callback response.
      #
      # @param result [Hash] Result of MWallet::Service#process_callback
      def notify_payment_async(result)
        order_id = result[:order_id]

        Thread.new do
          begin
            order = Order[order_id]
            unless order
              log_error('Cannot send payment notifications: order not found', order_id: order_id)
              next
            end

            # Create bot instance for notification
            bot = Telegram::Bot::Client.new(CoffeeBot::Config::TELEGRAM_BOT_TOKEN)
            notifier = Services::Notifier.new(bot)

            notifier.notify_payment_result(order, result)
            log_info('Payment notifications sent', order_id: order_id,
              refund_required: result[:refund_required] || false, payment_error: result[:payment_error])
          rescue StandardError => e
            log_error('Failed to send payment notifications',
              order_id: order_id,
              error: e.message,
              backtrace: e.backtrace&.first(3)
            )
          end
        end
      end
    end
  end
end
