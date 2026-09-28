# frozen_string_literal: true

# Multi-tenant schema: every coffee shop is a tenant with its own Telegram bot and
# its own O!Dengi (MWallet) merchant account. All business tables carry tenant_id.
#
# Money is stored as integers in tyiyn (1 KGS = 100 tyiyn), same unit as MWallet.
class CreateTenancyAndOrdering < ActiveRecord::Migration[8.1]
  ORDER_STATUSES = %w[NEW INVOICE_CREATED PAID IN_PROGRESS READY CANCELLED EXPIRED ERROR].freeze
  PAYMENT_STATUSES = %w[PENDING PAID FAILED REFUNDED_PARTIAL REFUNDED_FULL VOIDED REFUND_REQUIRED].freeze

  def change
    create_table :tenants do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.string :status, null: false, default: "active"
      t.string :time_zone, null: false, default: "Asia/Bishkek"
      t.integer :order_expire_minutes, null: false, default: 15
      t.jsonb :settings, null: false, default: {}
      t.timestamps
      t.check_constraint "status IN ('trial', 'active', 'suspended')", name: "tenants_status_check"
      t.check_constraint "order_expire_minutes BETWEEN 1 AND 120", name: "tenants_order_expire_minutes_check"
    end

    # One Telegram bot per coffee shop (created by the owner in @BotFather)
    create_table :bots do |t|
      t.references :tenant, null: false, foreign_key: true
      t.bigint :telegram_bot_id, null: false, index: { unique: true }
      t.string :username, null: false
      t.text :token, null: false # encrypted (Active Record Encryption)
      t.string :webhook_secret, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    # O!Dengi MWallet merchant credentials of the coffee shop
    create_table :payment_accounts do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :provider, null: false, default: "mwallet"
      t.string :sid, null: false
      t.text :password, null: false # encrypted
      t.string :base_url, null: false
      t.integer :api_version, null: false, default: 1005
      t.boolean :test_mode, null: false, default: true
      t.boolean :active, null: false, default: true
      t.timestamps
      t.check_constraint "provider IN ('mwallet')", name: "payment_accounts_provider_check"
    end

    create_table :staff_members do |t|
      t.references :tenant, null: false, foreign_key: true
      t.bigint :telegram_user_id, null: false
      t.string :name
      t.string :role, null: false, default: "barista"
      t.boolean :active, null: false, default: true
      t.timestamps
      t.index [ :tenant_id, :telegram_user_id ], unique: true
      t.check_constraint "role IN ('owner', 'manager', 'barista')", name: "staff_members_role_check"
    end

    # Telegram users of one coffee shop (the same person can be a customer of several)
    create_table :customers do |t|
      t.references :tenant, null: false, foreign_key: true
      t.bigint :telegram_user_id, null: false
      t.string :username
      t.string :first_name
      t.string :last_name
      t.string :language_code
      t.integer :orders_count, null: false, default: 0
      t.datetime :last_order_at
      t.timestamps
      t.index [ :tenant_id, :telegram_user_id ], unique: true
    end

    create_table :menu_items do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :category, null: false
      t.string :name, null: false
      t.integer :price, null: false
      t.string :currency, null: false, default: "KGS"
      t.boolean :available, null: false, default: true
      t.jsonb :sizes # {"small" => 13000, "medium" => 15000, "large" => 19000}
      t.string :default_size
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index [ :tenant_id, :category, :position ]
      t.check_constraint "price > 0", name: "menu_items_price_check"
    end

    # Order wizard / cart state of a customer
    create_table :drafts do |t|
      t.references :tenant, null: false, foreign_key: true
      t.bigint :telegram_user_id, null: false
      t.jsonb :state, null: false, default: {}
      t.timestamps
      t.index [ :tenant_id, :telegram_user_id ], unique: true
    end

    create_table :orders do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.references :payment_account, foreign_key: true
      t.bigint :telegram_user_id, null: false
      t.string :client_display_name, null: false
      t.string :comment, limit: 200
      t.string :status, null: false, default: "NEW"
      t.integer :total_amount, null: false
      t.string :currency, null: false, default: "KGS"
      t.string :merchant_invoice_id, null: false, index: { unique: true }
      t.string :provider
      t.string :invoice_id_provider
      t.text :qr_payload
      t.text :qr_url
      t.text :emv_qr_url
      t.text :qr_image_base64
      t.string :invoice_status_raw
      t.datetime :expires_at
      t.text :raw_create_response
      t.string :last_notified_status
      t.bigint :assigned_to_barista_id
      t.datetime :assigned_at
      t.timestamps
      t.index [ :tenant_id, :status, :created_at ]
      t.index [ :tenant_id, :telegram_user_id, :created_at ]
      t.index [ :payment_account_id, :invoice_id_provider ], unique: true, where: "invoice_id_provider IS NOT NULL"
      t.check_constraint "status IN (#{ORDER_STATUSES.map { |s| "'#{s}'" }.join(', ')})", name: "orders_status_check"
      t.check_constraint "total_amount > 0", name: "orders_total_amount_check"
    end

    create_table :order_items do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :order, null: false, foreign_key: { on_delete: :cascade }
      t.references :menu_item, foreign_key: { on_delete: :nullify }
      t.string :item_name, null: false
      t.string :size
      t.integer :qty, null: false
      t.integer :unit_price, null: false
      t.integer :line_total, null: false
      t.timestamps
      t.check_constraint "qty > 0", name: "order_items_qty_check"
      t.check_constraint "unit_price > 0 AND line_total > 0", name: "order_items_amounts_check"
    end

    # One payment record per order (paid, failed, refund required / refunded)
    create_table :payments do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :order, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :invoice_id_provider
      t.string :payment_id_provider
      t.integer :paid_amount
      t.integer :fee
      t.datetime :paid_at
      t.string :status, null: false, default: "PENDING"
      t.text :raw_status_response
      t.timestamps
      t.check_constraint "status IN (#{PAYMENT_STATUSES.map { |s| "'#{s}'" }.join(', ')})", name: "payments_status_check"
    end

    # Audit trail of refunds / voids
    create_table :payment_operations do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :order, null: false, foreign_key: { on_delete: :cascade }
      t.string :operation_type, null: false
      t.string :operation_id_provider
      t.integer :amount, null: false
      t.string :reason
      t.string :status, null: false, default: "PENDING"
      t.text :raw_request
      t.text :raw_response
      t.timestamps
      t.check_constraint "operation_type IN ('REFUND', 'VOID')", name: "payment_operations_type_check"
      t.check_constraint "status IN ('PENDING', 'COMPLETED', 'FAILED')", name: "payment_operations_status_check"
      t.check_constraint "amount > 0", name: "payment_operations_amount_check"
    end

    # Every incoming payment callback, for audit and deduplication
    create_table :callback_logs do |t|
      t.references :tenant, foreign_key: true
      t.references :payment_account, foreign_key: true
      t.string :provider, null: false, default: "MWALLET"
      t.string :event_id
      t.string :dedupe_key, index: true
      t.string :invoice_id_provider
      t.string :merchant_invoice_id
      t.text :raw_body, null: false
      t.boolean :verified_signature, null: false, default: false
      t.boolean :processed, null: false, default: false
      t.string :process_error
      t.datetime :received_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
      t.index [ :payment_account_id, :invoice_id_provider, :received_at ]
    end
  end
end
