# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_28_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bots", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "telegram_bot_id", null: false
    t.string "username", null: false
    t.text "token", null: false
    t.string "webhook_secret", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["telegram_bot_id"], name: "index_bots_on_telegram_bot_id", unique: true
    t.index ["tenant_id"], name: "index_bots_on_tenant_id"
  end

  create_table "callback_logs", force: :cascade do |t|
    t.bigint "tenant_id"
    t.bigint "payment_account_id"
    t.string "provider", default: "MWALLET", null: false
    t.string "event_id"
    t.string "dedupe_key"
    t.string "invoice_id_provider"
    t.string "merchant_invoice_id"
    t.text "raw_body", null: false
    t.boolean "verified_signature", default: false, null: false
    t.boolean "processed", default: false, null: false
    t.string "process_error"
    t.datetime "received_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dedupe_key"], name: "index_callback_logs_on_dedupe_key"
    t.index ["payment_account_id", "invoice_id_provider", "received_at"], name: "idx_on_payment_account_id_invoice_id_provider_recei_b1d7fb707e"
    t.index ["payment_account_id"], name: "index_callback_logs_on_payment_account_id"
    t.index ["tenant_id"], name: "index_callback_logs_on_tenant_id"
  end

  create_table "customers", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "telegram_user_id", null: false
    t.string "username"
    t.string "first_name"
    t.string "last_name"
    t.string "language_code"
    t.integer "orders_count", default: 0, null: false
    t.datetime "last_order_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "telegram_user_id"], name: "index_customers_on_tenant_id_and_telegram_user_id", unique: true
    t.index ["tenant_id"], name: "index_customers_on_tenant_id"
  end

  create_table "drafts", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "telegram_user_id", null: false
    t.jsonb "state", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "telegram_user_id"], name: "index_drafts_on_tenant_id_and_telegram_user_id", unique: true
    t.index ["tenant_id"], name: "index_drafts_on_tenant_id"
  end

  create_table "menu_items", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "category", null: false
    t.string "name", null: false
    t.integer "price", null: false
    t.string "currency", default: "KGS", null: false
    t.boolean "available", default: true, null: false
    t.jsonb "sizes"
    t.string "default_size"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "category", "position"], name: "index_menu_items_on_tenant_id_and_category_and_position"
    t.index ["tenant_id"], name: "index_menu_items_on_tenant_id"
    t.check_constraint "price > 0", name: "menu_items_price_check"
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "order_id", null: false
    t.bigint "menu_item_id"
    t.string "item_name", null: false
    t.string "size"
    t.integer "qty", null: false
    t.integer "unit_price", null: false
    t.integer "line_total", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["menu_item_id"], name: "index_order_items_on_menu_item_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["tenant_id"], name: "index_order_items_on_tenant_id"
    t.check_constraint "qty > 0", name: "order_items_qty_check"
    t.check_constraint "unit_price > 0 AND line_total > 0", name: "order_items_amounts_check"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "customer_id", null: false
    t.bigint "payment_account_id"
    t.bigint "telegram_user_id", null: false
    t.string "client_display_name", null: false
    t.string "comment", limit: 200
    t.string "status", default: "NEW", null: false
    t.integer "total_amount", null: false
    t.string "currency", default: "KGS", null: false
    t.string "merchant_invoice_id", null: false
    t.string "provider"
    t.string "invoice_id_provider"
    t.text "qr_payload"
    t.text "qr_url"
    t.text "emv_qr_url"
    t.text "qr_image_base64"
    t.string "invoice_status_raw"
    t.datetime "expires_at"
    t.text "raw_create_response"
    t.string "last_notified_status"
    t.bigint "assigned_to_barista_id"
    t.datetime "assigned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["merchant_invoice_id"], name: "index_orders_on_merchant_invoice_id", unique: true
    t.index ["payment_account_id", "invoice_id_provider"], name: "index_orders_on_payment_account_id_and_invoice_id_provider", unique: true, where: "(invoice_id_provider IS NOT NULL)"
    t.index ["payment_account_id"], name: "index_orders_on_payment_account_id"
    t.index ["tenant_id", "status", "created_at"], name: "index_orders_on_tenant_id_and_status_and_created_at"
    t.index ["tenant_id", "telegram_user_id", "created_at"], name: "index_orders_on_tenant_id_and_telegram_user_id_and_created_at"
    t.index ["tenant_id"], name: "index_orders_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['NEW'::character varying, 'INVOICE_CREATED'::character varying, 'PAID'::character varying, 'IN_PROGRESS'::character varying, 'READY'::character varying, 'CANCELLED'::character varying, 'EXPIRED'::character varying, 'ERROR'::character varying]::text[])", name: "orders_status_check"
    t.check_constraint "total_amount > 0", name: "orders_total_amount_check"
  end

  create_table "payment_accounts", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.string "provider", default: "mwallet", null: false
    t.string "sid", null: false
    t.text "password", null: false
    t.string "base_url", null: false
    t.integer "api_version", default: 1005, null: false
    t.boolean "test_mode", default: true, null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_payment_accounts_on_tenant_id"
    t.check_constraint "provider::text = 'mwallet'::text", name: "payment_accounts_provider_check"
  end

  create_table "payment_operations", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "order_id", null: false
    t.string "operation_type", null: false
    t.string "operation_id_provider"
    t.integer "amount", null: false
    t.string "reason"
    t.string "status", default: "PENDING", null: false
    t.text "raw_request"
    t.text "raw_response"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_payment_operations_on_order_id"
    t.index ["tenant_id"], name: "index_payment_operations_on_tenant_id"
    t.check_constraint "amount > 0", name: "payment_operations_amount_check"
    t.check_constraint "operation_type::text = ANY (ARRAY['REFUND'::character varying, 'VOID'::character varying]::text[])", name: "payment_operations_type_check"
    t.check_constraint "status::text = ANY (ARRAY['PENDING'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying]::text[])", name: "payment_operations_status_check"
  end

  create_table "payments", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "order_id", null: false
    t.string "invoice_id_provider"
    t.string "payment_id_provider"
    t.integer "paid_amount"
    t.integer "fee"
    t.datetime "paid_at"
    t.string "status", default: "PENDING", null: false
    t.text "raw_status_response"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_payments_on_order_id", unique: true
    t.index ["tenant_id"], name: "index_payments_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['PENDING'::character varying, 'PAID'::character varying, 'FAILED'::character varying, 'REFUNDED_PARTIAL'::character varying, 'REFUNDED_FULL'::character varying, 'VOIDED'::character varying, 'REFUND_REQUIRED'::character varying]::text[])", name: "payments_status_check"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", null: false
    t.binary "value", null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "staff_members", force: :cascade do |t|
    t.bigint "tenant_id", null: false
    t.bigint "telegram_user_id", null: false
    t.string "name"
    t.string "role", default: "barista", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "telegram_user_id"], name: "index_staff_members_on_tenant_id_and_telegram_user_id", unique: true
    t.index ["tenant_id"], name: "index_staff_members_on_tenant_id"
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying, 'manager'::character varying, 'barista'::character varying]::text[])", name: "staff_members_role_check"
  end

  create_table "telegram_updates", force: :cascade do |t|
    t.bigint "bot_id", null: false
    t.bigint "update_id", null: false
    t.datetime "created_at", null: false
    t.index ["bot_id", "update_id"], name: "index_telegram_updates_on_bot_id_and_update_id", unique: true
    t.index ["created_at"], name: "index_telegram_updates_on_created_at"
  end

  create_table "tenants", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "status", default: "active", null: false
    t.string "time_zone", default: "Asia/Bishkek", null: false
    t.integer "order_expire_minutes", default: 15, null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_tenants_on_slug", unique: true
    t.check_constraint "order_expire_minutes >= 1 AND order_expire_minutes <= 120", name: "tenants_order_expire_minutes_check"
    t.check_constraint "status::text = ANY (ARRAY['trial'::character varying, 'active'::character varying, 'suspended'::character varying]::text[])", name: "tenants_status_check"
  end

  add_foreign_key "bots", "tenants"
  add_foreign_key "callback_logs", "payment_accounts"
  add_foreign_key "callback_logs", "tenants"
  add_foreign_key "customers", "tenants"
  add_foreign_key "drafts", "tenants"
  add_foreign_key "menu_items", "tenants"
  add_foreign_key "order_items", "menu_items", on_delete: :nullify
  add_foreign_key "order_items", "orders", on_delete: :cascade
  add_foreign_key "order_items", "tenants"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "payment_accounts"
  add_foreign_key "orders", "tenants"
  add_foreign_key "payment_accounts", "tenants"
  add_foreign_key "payment_operations", "orders", on_delete: :cascade
  add_foreign_key "payment_operations", "tenants"
  add_foreign_key "payments", "orders", on_delete: :cascade
  add_foreign_key "payments", "tenants"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "staff_members", "tenants"
  add_foreign_key "telegram_updates", "bots", on_delete: :cascade
end
