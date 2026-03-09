# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Integration tests' do
  describe 'Callback deduplication' do
    it 'prevents duplicate callback processing' do
      # Create order
      order = create_test_order(create_test_client)
      order.update(
        status: OrderStatus::INVOICE_CREATED,
        invoice_id_provider: 'INV-123'
      )

      # First callback
      callback1 = CallbackLog.log_callback(
        event_id: 'EVT-001',
        invoice_id: 'INV-123',
        merchant_invoice_id: order.merchant_invoice_id,
        raw_body: '{"status":"PAID"}',
        verified: true
      )

      # Check duplicate detection
      is_duplicate = CallbackLog.duplicate?('EVT-001', 'INV-123', '{"status":"PAID"}')
      
      expect(is_duplicate).to be true
    end

    it 'allows different callbacks' do
      callback1 = CallbackLog.log_callback(
        event_id: 'EVT-001',
        invoice_id: 'INV-123',
        raw_body: '{"status":"PAID"}',
        verified: true
      )

      callback2 = CallbackLog.log_callback(
        event_id: 'EVT-002',
        invoice_id: 'INV-123',
        raw_body: '{"status":"PAID"}',
        verified: true
      )

      expect(CallbackLog.duplicate?('EVT-002', 'INV-123', '{"status":"PAID"}')).to be false
    end
  end

  describe 'Refund limits' do
    it 'prevents refund exceeding paid amount' do
      client = create_test_client
      order = create_test_order(client, amount: 10_000)
      order.update(status: OrderStatus::PAID)

      # Create payment
      payment = Payment.create(
        order_id: order.id,
        invoice_id_provider: 'INV-123',
        paid_amount: 10_000,
        status: PaymentStatus::PAID
      )

      # Try to refund more than paid
      expect(payment.can_refund?(15_000)).to be false
    end

    it 'allows partial refund' do
      client = create_test_client
      order = create_test_order(client, amount: 10_000)
      order.update(status: OrderStatus::PAID)

      payment = Payment.create(
        order_id: order.id,
        invoice_id_provider: 'INV-123',
        paid_amount: 10_000,
        status: PaymentStatus::PAID
      )

      expect(payment.can_refund?(5_000)).to be true
    end

    it 'prevents double refund of same amount' do
      client = create_test_client
      order = create_test_order(client, amount: 10_000)
      order.update(status: OrderStatus::PAID)

      payment = Payment.create(
        order_id: order.id,
        invoice_id_provider: 'INV-123',
        paid_amount: 10_000,
        status: PaymentStatus::PAID
      )

      # First refund
      PaymentOperation.create(
        order_id: order.id,
        operation_type: PaymentOperationType::REFUND,
        amount: 7_000,
        status: PaymentOperationStatus::COMPLETED
      )

      # Remaining refundable should be 3_000
      expect(payment.remaining_refundable).to eq(3_000)
      expect(payment.can_refund?(5_000)).to be false
      expect(payment.can_refund?(3_000)).to be true
    end
  end

  describe 'Atomic claim race condition' do
    it 'ensures only one barista can claim an order' do
      # Simulate concurrent claims
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::PAID)

      results = []
      threads = []

      # Simulate 5 concurrent claims
      5.times do |i|
        threads << Thread.new do
          result = order.claim_for_barista!(i)
          results << result
        end
      end

      threads.each(&:join)

      # Only one should succeed
      successful_claims = results.count(true)
      expect(successful_claims).to eq(1)
    end
  end

  describe 'Draft cart operations' do
    it 'adds items to cart' do
      draft = create_test_draft(123_456_789)
      item = create_test_menu_item

      draft.add_item(item, 2)

      expect(draft.items.length).to eq(1)
      expect(draft.items.first['qty']).to eq(2)
      expect(draft.total_amount).to eq(20_000)
    end

    it 'accumulates quantity for same item' do
      draft = create_test_draft(123_456_789)
      item = create_test_menu_item

      draft.add_item(item, 2)
      draft.add_item(item, 3)

      expect(draft.items.length).to eq(1)
      expect(draft.items.first['qty']).to eq(5)
      expect(draft.total_amount).to eq(50_000)
    end

    it 'calculates total correctly' do
      draft = create_test_draft(123_456_789)
      
      item1 = create_test_menu_item(name: 'Капучино', price: 15_000)
      item2 = create_test_menu_item(name: 'Латте', price: 16_000)

      draft.add_item(item1, 2) # 30_000
      draft.add_item(item2, 1) # 16_000

      expect(draft.total_amount).to eq(46_000)
      expect(draft.formatted_total).to eq('460 KGS')
    end
  end
end
