# Coffee-Bot Production-Ready Implementation Plan

## Overview

This plan outlines the complete refactoring of the coffee-bot project from a simple prototype to a production-ready Telegram bot with:
- Full O!Деньги QRPay payment integration
- Structured menu system
- Barista queue management
- SQLite → PostgreSQL migration path

---

## Architecture Overview

```mermaid
graph TB
    subgraph Telegram
        A[Client]
        B[Barista]
    end

    subgraph Application
        C[Bot Polling]
        D[HTTP Callback Server]
        E[Background Jobs]
    end

    subgraph Services
        F[OrderService]
        G[MenuService]
        H[AuthService]
        I[Notifier]
        J[QRPayService]
    end

    subgraph Database
        K[(PostgreSQL/SQLite)]
    end

    subgraph External
        L[O!Деньги QRPay API]
    end

    A --> C
    B --> C
    C --> F
    C --> G
    C --> H
    F --> J
    J --> L
    L --> D
    D --> F
    E --> K
    F --> K
    G --> K
    I --> A
    I --> B
```

---

## Phase 1: Project Structure & Configuration

### Tasks

1. **Create directory structure**
   ```
   /bin/bot                    # Telegram polling entry point
   /bin/callback_app           # HTTP callback server entry point
   /config/boot.rb             # dotenv + logger + db init
   /config/database.rb         # Sequel connection + plugins
   /db/migrations/             # Sequel migrations
   /lib/bot/router.rb          # Command/callback dispatcher
   /lib/bot/handlers/client/   # Client scenarios
   /lib/bot/handlers/barista/  # Barista scenarios
   /lib/models/                # Sequel::Model classes
   /lib/services/              # Business logic services
   /lib/services/qrpay/        # QRPay integration module
   /lib/http/callback_app.rb   # Rack/Sinatra callback server
   /spec/                      # RSpec tests
   /data/reports/              # CSV reports storage
   ```

2. **Update Gemfile**
   - Add `sinatra` (for callback server)
   - Add `rspec` (for testing)
   - Add `rackup` (for Rack handler)
   - Add `puma` (for HTTP server)
   - Add `json-jwt` or custom signer for QRPay signatures

3. **Create config/boot.rb**
   - Load dotenv
   - Configure logger with JSON format
   - Initialize database connection

4. **Create config/database.rb**
   - Sequel connection from DATABASE_URL
   - Support both sqlite:// and postgres:// URLs
   - Add model plugins: timestamps, validation

5. **Update .env.example**
   - All required environment variables documented

---

## Phase 2: Database Schema & Migrations

### Migration Files

#### 001_create_menu_items.rb
```ruby
create_table :menu_items do
  primary_key :id
  String :category, null: false
  String :name, null: false
  Integer :price, null: false        # in tyiyn
  String :currency, default: 'KGS'
  TrueClass :is_available, default: true
  DateTime :updated_at
end
```

#### 002_create_clients.rb
```ruby
create_table :clients do
  BigInt :telegram_user_id, primary_key: true
  String :username
  String :first_name
  String :last_name
  DateTime :created_at
  Integer :orders_count, default: 0
  DateTime :last_order_at
end
```

#### 003_create_drafts.rb
```ruby
create_table :drafts do
  primary_key :id
  BigInt :telegram_user_id, unique: true, null: false
  String :state_json, text: true, null: false
  DateTime :updated_at
end
```

#### 004_create_orders.rb
```ruby
create_table :orders do
  primary_key :id
  String :provider, default: 'ODENGI_QRPAY'
  String :merchant_invoice_id, unique: true, null: false
  BigInt :telegram_user_id, null: false, index: true
  String :client_display_name, null: false
  String :comment, size: 200
  String :status, null: false
  Integer :total_amount, null: false
  String :currency, default: 'KGS'
  DateTime :created_at, null: false
  DateTime :updated_at, null: false
  
  # Barista assignment
  BigInt :assigned_to_barista_id
  DateTime :assigned_at
  
  # QRPay invoice data
  String :invoice_id_provider, index: true
  String :qr_payload, text: true
  String :qr_url, text: true
  String :qr_image_base64, text: true
  String :invoice_status_raw
  DateTime :expires_at
  
  # Diagnostics
  String :raw_create_request, text: true
  String :raw_create_response, text: true
  
  # Notifications
  String :last_notified_status
  
  index [:status, :created_at]
  index [:telegram_user_id, :created_at]
end
```

#### 005_create_order_items.rb
```ruby
create_table :order_items do
  primary_key :id
  foreign_key :order_id, :orders, index: true
  foreign_key :menu_item_id, :menu_items
  String :item_name, null: false     # snapshot
  Integer :qty, null: false
  Integer :unit_price, null: false   # snapshot
  Integer :line_total, null: false
end
```

#### 006_create_payments.rb
```ruby
create_table :payments do
  primary_key :id
  foreign_key :order_id, :orders
  String :invoice_id_provider, index: true
  String :payment_id_provider
  Integer :paid_amount
  Integer :fee
  DateTime :paid_at
  String :status, null: false
  String :raw_status_response, text: true
end
```

#### 007_create_payment_operations.rb
```ruby
create_table :payment_operations do
  primary_key :id
  foreign_key :order_id, :orders
  String :operation_type, null: false  # REFUND | VOID
  String :operation_id_provider
  Integer :amount, null: false
  String :reason
  String :status, null: false
  DateTime :created_at, null: false
  String :raw_request, text: true
  String :raw_response, text: true
end
```

#### 008_create_callback_logs.rb
```ruby
create_table :callback_logs do
  primary_key :id
  String :provider, default: 'ODENGI_QRPAY'
  String :event_id
  String :invoice_id_provider, index: true
  String :merchant_invoice_id, index: true
  DateTime :received_at, null: false
  String :raw_body, text: true, null: false
  TrueClass :verified_signature, default: false
  TrueClass :processed, default: false
  String :process_error
  String :dedupe_key, index: true
  
  index :event_id
end
```

#### 009_create_reports.rb
```ruby
create_table :reports do
  primary_key :id
  String :provider, default: 'ODENGI_QRPAY'
  Date :date_from, null: false
  Date :date_to, null: false
  String :filters_json, text: true
  String :file_path, null: false
  String :checksum
  DateTime :created_at, null: false
end
```

---

## Phase 3: Models & Domain Logic

### Models to Create

| Model | File | Key Features |
|-------|------|--------------|
| MenuItem | `lib/models/menu_item.rb` | Categories, availability toggle |
| Client | `lib/models/client.rb` | Telegram user data, order stats |
| Draft | `lib/models/draft.rb` | JSON state for order wizard |
| Order | `lib/models/order.rb` | State machine, status transitions |
| OrderItem | `lib/models/order_item.rb` | Snapshot of menu items |
| Payment | `lib/models/payment.rb` | Payment tracking |
| PaymentOperation | `lib/models/payment_operation.rb` | Refund/void journal |
| CallbackLog | `lib/models/callback_log.rb` | Deduplication |
| Report | `lib/models/report.rb` | CSV report metadata |

### Order State Machine

```mermaid
stateDiagram-v2
    [*] --> NEW: create order
    NEW --> INVOICE_CREATED: createInvoice success
    INVOICE_CREATED --> PAID: callback/status sync
    INVOICE_CREATED --> EXPIRED: TTL expired
    PAID --> IN_PROGRESS: barista claim
    IN_PROGRESS --> READY: barista complete
    PAID --> CANCELLED: cancel
    IN_PROGRESS --> CANCELLED: cancel
```

### Status Constants
```ruby
module OrderStatus
  NEW = 'NEW'
  INVOICE_CREATED = 'INVOICE_CREATED'
  PAID = 'PAID'
  IN_PROGRESS = 'IN_PROGRESS'
  READY = 'READY'
  CANCELLED = 'CANCELLED'
  EXPIRED = 'EXPIRED'
  ERROR = 'ERROR'
end
```

---

## Phase 4: QRPay Integration Service

### Module Structure

```
lib/services/qrpay/
├── qrpay_client.rb      # HTTP client for QRPay API
├── qrpay_service.rb     # High-level business operations
├── signer.rb            # Request/response signing
├── status_mapper.rb     # Provider status → internal status
└── errors.rb            # Custom error classes
```

### Key Methods

| Method | Description |
|--------|-------------|
| `create_invoice(order)` | Create payment invoice, return QR data |
| `get_invoice_status(invoice_id)` | Check payment status |
| `cancel_invoice(invoice_id)` | Cancel pending invoice |
| `refund_partial(order, amount)` | Partial refund |
| `void_payment(order)` | Void payment |
| `get_history_csv(from, to)` | Download transaction report |

### Error Handling
```ruby
module QRPayError
  class AuthError < StandardError; end
  class ValidationError < StandardError; end
  class ProviderTimeout < StandardError; end
  class ProviderError < StandardError; end
  class BusinessError < StandardError; end
end
```

---

## Phase 5: Order & Menu Services

### Services to Create

| Service | File | Responsibilities |
|---------|------|------------------|
| AuthService | `lib/services/auth_service.rb` | Barista whitelist check |
| MenuService | `lib/services/menu_service.rb` | CRUD menu items, categories |
| OrderService | `lib/services/order_service.rb` | Order lifecycle, status transitions |
| Notifier | `lib/services/notifier.rb` | Telegram notifications |

### OrderService Key Methods
```ruby
class OrderService
  def create_order(client, items, comment)
  def add_invoice_data(order, invoice_response)
  def mark_paid(order, payment_data)
  def claim_order(order, barista_id)  # atomic
  def complete_order(order, barista_id)
  def cancel_order(order)
  def expire_order(order)
end
```

---

## Phase 6: Telegram Bot Handlers (Client)

### Client Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant B as Bot
    participant S as OrderService
    participant Q as QRPayService
    participant DB as Database

    C->>B: /start
    B->>C: Show menu keyboard
    
    C->>B: Make order
    B->>C: Show categories
    C->>B: Select category
    B->>C: Show items with prices
    C->>B: Select item
    B->>C: Ask quantity
    C->>B: Enter qty
    B->>C: Show cart + Add more/Checkout
    
    C->>B: Checkout
    B->>S: create_order
    S->>DB: Save order NEW
    S->>Q: create_invoice
    Q->>DB: Save invoice data
    S->>DB: Update INVOICE_CREATED
    B->>C: Send QR code + payment link
```

### Handler Files
- `lib/bot/handlers/client/start_handler.rb`
- `lib/bot/handlers/client/menu_handler.rb`
- `lib/bot/handlers/client/order_wizard_handler.rb`
- `lib/bot/handlers/client/my_orders_handler.rb`
- `lib/bot/handlers/client/payment_handler.rb`

---

## Phase 7: Telegram Bot Handlers (Barista)

### Barista Flow

```mermaid
sequenceDiagram
    participant B as Barista
    participant Bot as Bot
    participant S as OrderService
    participant N as Notifier
    participant C as Client

    B->>Bot: /barista
    Bot->>B: Show barista panel
    
    B->>Bot: Queue PAID
    Bot->>S: get_paid_orders
    S->>Bot: List of PAID orders
    Bot->>B: Show order cards
    
    B->>Bot: Accept order
    Bot->>S: claim_order atomic
    S->>Bot: Success
    Bot->>N: Notify client
    N->>C: Your order is being prepared
    
    B->>Bot: Mark ready
    Bot->>S: complete_order
    Bot->>N: Notify client
    N->>C: Your order is ready
```

### Handler Files
- `lib/bot/handlers/barista/panel_handler.rb`
- `lib/bot/handlers/barista/queue_handler.rb`
- `lib/bot/handlers/barista/order_action_handler.rb`
- `lib/bot/handlers/barista/menu_management_handler.rb`

---

## Phase 8: HTTP Callback Server

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| POST | `/callbacks/odengi/qrpay/result` | QRPay payment callback |

### Callback Processing Flow

```mermaid
sequenceDiagram
    participant QP as QRPay
    participant S as Sinatra App
    participant CL as CallbackLog
    participant OS as OrderService
    participant N as Notifier

    QP->>S: POST /callbacks/odengi/qrpay/result
    S->>CL: Log raw_body
    S->>S: Verify signature
    
    alt Invalid signature
        S->>QP: 401 Unauthorized
    end
    
    S->>CL: Check dedupe
    alt Duplicate
        S->>QP: 200 OK
    end
    
    S->>OS: Process payment
    OS->>N: Notify client if PAID
    S->>CL: Mark processed
    S->>QP: 200 OK
```

---

## Phase 9: Background Jobs

### Job: Expire Invoices

Runs every 60 seconds:
1. Find orders with `status = INVOICE_CREATED` and `created_at < now - ORDER_EXPIRE_MINUTES`
2. Update status to `EXPIRED`
3. Send notification to client

### Job: Fallback Status Sync

Runs every 5 minutes (optional):
1. Find orders with `status = INVOICE_CREATED` and not expired
2. Call `getInvoiceStatus` for each
3. Update status if changed

---

## Phase 10: Testing (RSpec)

### Test Files

| Spec | Description |
|------|-------------|
| `spec/services/order_service_spec.rb` | Order creation, status transitions |
| `spec/services/qrpay_service_spec.rb` | Invoice creation, idempotency |
| `spec/models/order_spec.rb` | State machine transitions |
| `spec/integration/claim_order_spec.rb` | Atomic claim race condition |
| `spec/integration/callback_dedupe_spec.rb` | Duplicate callback handling |

### Key Test Cases

1. **Total calculation**: Verify `total_amount = sum(items.line_total)`
2. **CreateInvoice idempotency**: Second call returns existing invoice
3. **Status transitions**: Invalid transitions raise error
4. **Atomic claim**: Two baristas, one winner
5. **Callback deduplication**: Same event_id processed once
6. **Refund limits**: Cannot refund more than paid

---

## Phase 11: Docker & Deployment

### docker-compose.yml

```yaml
version: '3.8'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: coffee_bot
      POSTGRES_USER: coffee
      POSTGRES_PASSWORD: secret
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  bot:
    build: .
    command: bin/bot
    environment:
      DATABASE_URL: postgres://coffee:secret@postgres:5432/coffee_bot
    depends_on:
      - postgres

  callback_app:
    build: .
    command: bin/callback_app
    ports:
      - "9292:9292"
    environment:
      DATABASE_URL: postgres://coffee:secret@postgres:5432/coffee_bot
    depends_on:
      - postgres

volumes:
  postgres_data:
```

### Dockerfile

```dockerfile
FROM ruby:3.2
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .
CMD ["bin/bot"]
```

---

## Phase 12: Documentation (README)

### README Sections

1. **Overview** - Project description
2. **Prerequisites** - Ruby, SQLite/PostgreSQL
3. **Installation** - `bundle install`
4. **Configuration** - Environment variables
5. **Running on SQLite** (dev)
6. **Running on PostgreSQL** (docker-compose)
7. **Database Migrations** - Sequel commands
8. **Adding Baristas** - BARISTA_WHITELIST
9. **Menu Management** - Commands/SQL
10. **QRPay Sandbox Testing** - How to test payments
11. **Troubleshooting** - Common issues

---

## File Creation Checklist

### Configuration Files
- [ ] `Gemfile` (updated)
- [ ] `.env.example`
- [ ] `config/boot.rb`
- [ ] `config/database.rb`
- [ ] `docker-compose.yml`
- [ ] `Dockerfile`
- [ ] `.dockerignore`

### Entry Points
- [ ] `bin/bot`
- [ ] `bin/callback_app`

### Migrations
- [ ] `db/migrations/001_create_menu_items.rb`
- [ ] `db/migrations/002_create_clients.rb`
- [ ] `db/migrations/003_create_drafts.rb`
- [ ] `db/migrations/004_create_orders.rb`
- [ ] `db/migrations/005_create_order_items.rb`
- [ ] `db/migrations/006_create_payments.rb`
- [ ] `db/migrations/007_create_payment_operations.rb`
- [ ] `db/migrations/008_create_callback_logs.rb`
- [ ] `db/migrations/009_create_reports.rb`

### Models
- [ ] `lib/models/menu_item.rb`
- [ ] `lib/models/client.rb`
- [ ] `lib/models/draft.rb`
- [ ] `lib/models/order.rb`
- [ ] `lib/models/order_item.rb`
- [ ] `lib/models/payment.rb`
- [ ] `lib/models/payment_operation.rb`
- [ ] `lib/models/callback_log.rb`
- [ ] `lib/models/report.rb`

### Services
- [ ] `lib/services/auth_service.rb`
- [ ] `lib/services/menu_service.rb`
- [ ] `lib/services/order_service.rb`
- [ ] `lib/services/notifier.rb`
- [ ] `lib/services/qrpay/errors.rb`
- [ ] `lib/services/qrpay/signer.rb`
- [ ] `lib/services/qrpay/status_mapper.rb`
- [ ] `lib/services/qrpay/qrpay_client.rb`
- [ ] `lib/services/qrpay/qrpay_service.rb`

### Bot Handlers
- [ ] `lib/bot/router.rb`
- [ ] `lib/bot/handlers/client/start_handler.rb`
- [ ] `lib/bot/handlers/client/menu_handler.rb`
- [ ] `lib/bot/handlers/client/order_wizard_handler.rb`
- [ ] `lib/bot/handlers/client/my_orders_handler.rb`
- [ ] `lib/bot/handlers/client/payment_handler.rb`
- [ ] `lib/bot/handlers/barista/panel_handler.rb`
- [ ] `lib/bot/handlers/barista/queue_handler.rb`
- [ ] `lib/bot/handlers/barista/order_action_handler.rb`
- [ ] `lib/bot/handlers/barista/menu_management_handler.rb`

### HTTP Server
- [ ] `lib/http/callback_app.rb`

### Background Jobs
- [ ] `lib/jobs/invoice_expirer.rb`
- [ ] `lib/jobs/status_syncer.rb`

### Tests
- [ ] `spec/spec_helper.rb`
- [ ] `spec/services/order_service_spec.rb`
- [ ] `spec/services/qrpay_service_spec.rb`
- [ ] `spec/models/order_spec.rb`
- [ ] `spec/integration/claim_order_spec.rb`
- [ ] `spec/integration/callback_dedupe_spec.rb`

### Documentation
- [ ] `README.md`

---

## Next Steps

1. Review this plan and confirm priorities
2. Switch to Code mode for implementation
3. Start with Phase 1 (Project Structure)
4. Progress through phases sequentially
