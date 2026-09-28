# frozen_string_literal: true

# Report Model
# Tracks generated CSV reports from QRPay

require_relative '../../config/boot'

class Report < Sequel::Model
  # Validations
  def validate
    super
    errors.add(:date_from, 'cannot be nil') if date_from.nil?
    errors.add(:date_to, 'cannot be nil') if date_to.nil?
    errors.add(:file_path, 'cannot be empty') if file_path.nil? || file_path.empty?
  end

  # Scopes
  dataset_module do
    def for_provider(provider)
      where(provider: provider)
    end

    def for_date_range(from, to)
      where(date_from: from, date_to: to).first
    end

    def recent(limit = 10)
      order(Sequel.desc(:created_at)).limit(limit)
    end
  end

  # Class methods

  # Check if report already exists for date range
  def self.exists_for_range?(from, to, provider = 'ODENGI_QRPAY')
    !for_date_range(from, to).nil?
  end

  # Create report record
  def self.create_report(params)
    create(
      provider: params[:provider] || 'ODENGI_QRPAY',
      date_from: params[:date_from],
      date_to: params[:date_to],
      filters_json: params[:filters]&.to_json,
      file_path: params[:file_path],
      checksum: params[:checksum]
    )
  end

  # Instance methods

  # Check if file exists
  def file_exists?
    File.exist?(file_path)
  end

  # Delete file and record
  def delete_with_file!
    File.delete(file_path) if file_exists?
    destroy
  end

  # Format date range for display
  def date_range_display
    "#{date_from} - #{date_to}"
  end
end
