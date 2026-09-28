require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Telegram webhooks and O!Dengi callbacks only reach HTTPS URLs. TLS is terminated in
  # front of Puma (a reverse proxy, a tunnel, or Thruster with TLS_DOMAIN), so every
  # request is treated as HTTPS even when the proxy does not send X-Forwarded-Proto.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT (docker compose logs) with the current request id as a default log tag.
  # AppLog lines add tenant_id / order_id themselves.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # Solid Queue lives in the primary database (config/queue.yml). Workers run inside Puma
  # with SOLID_QUEUE_IN_PUMA=true (config/puma.rb) or as a separate bin/jobs process.
  config.active_job.queue_adapter = :solid_queue

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # The only host this app answers for: the one Telegram and O!Dengi are given (PUBLIC_BASE_URL)
  public_host = URI.parse(config.x.public_base_url).host
  raise "PUBLIC_BASE_URL must be an absolute URL, e.g. https://coffee.example.com" if public_host.blank?

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: public_host, protocol: "https" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via bin/rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks: only the PUBLIC_BASE_URL
  # host, plus optional extra names in RAILS_EXTRA_HOSTS (comma-separated).
  config.hosts = [ public_host, *ENV.fetch("RAILS_EXTRA_HOSTS", "").split(",").map(&:strip) ].compact_blank

  # Skip DNS rebinding protection for the default health check endpoint (Docker probes it
  # by container address).
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
