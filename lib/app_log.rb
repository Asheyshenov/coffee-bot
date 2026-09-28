# frozen_string_literal: true

# Structured log lines: AppLog.info("Order paid", order_id: 1, tenant_id: 2)
# -> "Order paid order_id=1 tenant_id=2"
module AppLog
  module_function

  def info(message, **context) = Rails.logger.info(format_line(message, context))
  def warn(message, **context) = Rails.logger.warn(format_line(message, context))
  def error(message, **context) = Rails.logger.error(format_line(message, context))

  def format_line(message, context)
    tenant_id = ActsAsTenant.current_tenant&.id
    context = { tenant_id: tenant_id, **context } if tenant_id && !context.key?(:tenant_id)
    return message if context.empty?

    "#{message} #{context.map { |k, v| "#{k}=#{v.is_a?(String) ? v.inspect : v}" }.join(' ')}"
  end
end
