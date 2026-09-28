# frozen_string_literal: true

# Migration: Create payment_operations table
# Journal of refund and void operations for audit trail

Sequel.migration do
  up do
    create_table :payment_operations do
      primary_key :id
      
      # Reference to the order
      foreign_key :order_id, :orders, on_delete: :cascade, null: false
      
      # Operation type
      String :operation_type, null: false  # REFUND | VOID
      
      # Provider operation ID
      String :operation_id_provider
      
      # Operation details
      Integer :amount, null: false         # Amount in tyiyn
      String :reason                       # Reason for refund/void
      
      # Operation status
      # PENDING | COMPLETED | FAILED
      String :status, null: false, default: 'PENDING'
      
      # Timestamps
      DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at
      
      # Raw request/response for debugging
      String :raw_request, text: true
      String :raw_response, text: true
    end
    
    add_index :payment_operations, :order_id
    add_index :payment_operations, [:operation_type, :status]
  end

  down do
    drop_table :payment_operations
  end
end
