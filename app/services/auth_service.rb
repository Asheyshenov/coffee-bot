# frozen_string_literal: true

# Who may use the barista panel of the current coffee shop.
# Every active staff member of the tenant counts as a barista (replaces BARISTA_WHITELIST).
class AuthService
  # @param telegram_user_id [Integer]
  def self.barista?(telegram_user_id)
    return false if telegram_user_id.blank?

    StaffMember.active.exists?(telegram_user_id: telegram_user_id)
  end

  def self.barista_configured? = StaffMember.active.exists?

  # Telegram IDs of the active staff of the current coffee shop
  def self.all_baristas = StaffMember.active.order(:id).pluck(:telegram_user_id)
end
