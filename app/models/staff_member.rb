# frozen_string_literal: true

# A person working in the coffee shop, identified by their Telegram account.
# Every active staff member can use the barista panel.
class StaffMember < ApplicationRecord
  ROLES = %w[owner manager barista].freeze

  acts_as_tenant :tenant

  validates :telegram_user_id, presence: true, uniqueness: { scope: :tenant_id }
  validates :role, inclusion: { in: ROLES }

  scope :active, -> { where(active: true) }
end
