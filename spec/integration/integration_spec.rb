# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Integration tests' do
  describe 'Callback deduplication' do
    # A callback is a duplicate only if an identical one (same provider event id, or
    # same raw body for the same invoice) was already verified AND processed.
    # The check runs BEFORE the new callback is logged, so it never finds itself.
    # Real idempotency comes from the atomic status transition (Order#mark_paid!).
    it 'prevents duplicate callback processing' do
      # Create order
      order = create_test_order(create_test_client)
      order.update(
        status: OrderStatus::INVOICE_CREATED,
        invoice_id_provider: 'INV-123'
      )

      # First callback, verified and processed
      callback1 = CallbackLog.log_callback(
        event_id: 'EVT-001',
        invoice_id: 'INV-123',
        merchant_invoice_id: order.merchant_invoice_id,
        raw_body: '{"status":"PAID"}',
        verified: true
      )
      callback1.mark_processed!

      # Same event id, or the same body for the same invoice (MWallet has no event id)
      expect(CallbackLog.duplicate?('EVT-001', 'INV-123', '{"status":"PAID"}')).to be true
      expect(CallbackLog.duplicate?(nil, 'INV-123', '{"status":"PAID"}')).to be true
    end

    it 'allows different callbacks' do
      # Pending callback for the invoice was handled...
      CallbackLog.log_callback(
        event_id: 'EVT-001',
        invoice_id: 'INV-123',
        raw_body: '{"status":1}',
        verified: true
      ).mark_processed!

      # ...a new event / new body for the same invoice (pending -> paid) is not a duplicate
      expect(CallbackLog.duplicate?('EVT-002', 'INV-123', '{"status":3}')).to be false
      expect(CallbackLog.duplicate?(nil, 'INV-123', '{"status":3}')).to be false
    end

    it 'does not treat unprocessed or failed callbacks as duplicates (provider retry is processed)' do
      # Crashed mid-processing
      CallbackLog.log_callback(invoice_id: 'INV-123', raw_body: '{"status":3}', verified: true)
      # Failed with an error
      CallbackLog.log_callback(invoice_id: 'INV-123', raw_body: '{"status":3}', verified: true)
                 .mark_failed!('database is locked')

      expect(CallbackLog.duplicate?(nil, 'INV-123', '{"status":3}')).to be false
    end

    it 'logs several callbacks for the same invoice without a unique event_id conflict' do
      2.times { CallbackLog.log_callback(invoice_id: 'INV-123', raw_body: '{"status":1}', verified: true) }

      expect(CallbackLog.by_invoice_id('INV-123').count).to eq(2)
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
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::PAID)

      # Five baristas each hold an instance loaded while the order was still PAID.
      # (Real threads can't be used: every connection to sqlite::memory: is a separate DB.)
      stale_copies = Array.new(5) { Order[order.id] }
      results = stale_copies.each_with_index.map { |copy, barista_id| copy.claim_for_barista!(barista_id) }

      expect(results.count(true)).to eq(1)
      expect(order.refresh.assigned_to_barista_id).to eq(0)
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
