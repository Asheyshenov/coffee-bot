# frozen_string_literal: true

# A coffee shop using the platform. Owns its bot, payment account, menu, staff and orders.
class Tenant < ApplicationRecord
  STATUSES = %w[trial active suspended].freeze

  # Destroy order matters: orders reference customers and payment accounts
  has_many :orders, dependent: :destroy
  has_many :callback_logs, dependent: :delete_all
  has_many :drafts, dependent: :destroy
  has_many :customers, dependent: :destroy
  has_many :menu_items, dependent: :destroy
  has_many :staff_members, dependent: :destroy
  has_many :payment_accounts, dependent: :destroy
  has_many :bots, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9-]*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :order_expire_minutes, numericality: { only_integer: true, in: 1..120 }

  scope :serving, -> { where(status: %w[trial active]) }

  def serving? = status.in?(%w[trial active])

  # The bot customers talk to
  def bot = bots.find_by(active: true)

  # The O!Dengi account invoices are issued from
  def payment_account = payment_accounts.find_by(active: true)
end
