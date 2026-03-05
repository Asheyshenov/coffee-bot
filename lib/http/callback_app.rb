# frozen_string_literal: true

# HTTP Callback Server
# Sinatra app for receiving QRPay payment callbacks

require 'sinatra/base'
require 'json'

module CoffeeBot
  module HTTP
    class CallbackApp < Sinatra::Base
      # Disable Sinatra logging (use our own)
      set :logging, false

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

      # QRPay callback endpoint
      post '/callbacks/odengi/qrpay/result' do
        request.body.rewind
        raw_body = request.body.read
        
        log_info('Received QRPay callback', 
          content_type: request.content_type,
          body_length: raw_body.length
        )

        begin
          # Parse callback data
          params = parse_callback_data(raw_body, request.content_type)
          
          # Get signature from header
          signature = request.env['HTTP_X_SIGNATURE'] || 
                      request.env['HTTP_SIGNATURE'] ||
                      params['signature']

          # Process callback
          Services::OrderService.process_payment_callback(params, raw_body, signature)

          { status: 'ok' }.to_json

        rescue QRPayError::SignatureError => e
          log_error('Callback signature verification failed', error: e.message)
          halt 401, { error: 'Invalid signature' }.to_json

        rescue JSON::ParserError => e
          log_error('Invalid JSON in callback', error: e.message)
          halt 400, { error: 'Invalid JSON' }.to_json

        rescue StandardError => e
          log_error('Callback processing error', 
            error: e.message, 
            backtrace: e.backtrace&.first(3)
          )
          # Return 200 to acknowledge receipt (don't retry)
          { status: 'error', message: e.message }.to_json
        end
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
      def parse_callback_data(raw_body, content_type)
        if content_type&.include?('application/json')
          JSON.parse(raw_body)
        elsif content_type&.include?('application/x-www-form-urlencoded')
          # Parse form data, converting to indifferent access
          Rack::Utils.parse_nested_query(raw_body).transform_keys(&:to_s)
        else
          # Try JSON first, then form data
          begin
            JSON.parse(raw_body)
          rescue JSON::ParserError
            Rack::Utils.parse_nested_query(raw_body).transform_keys(&:to_s)
          end
        end
      end
    end
  end
end
