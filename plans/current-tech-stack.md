# Coffee-Bot: Current Tech Stack

## Project Overview

The project consists of **two components**:

1. **Ruby Telegram Bot** - Backend service for coffee ordering via Telegram
2. **Flutter Mobile App** (Red Cup) - Mobile client for Giraffe Coffee chain

---

## 1. Ruby Telegram Bot

### Core Technologies

| Component | Technology | Version |
|-----------|------------|---------|
| **Language** | Ruby | (system version) |
| **Telegram API** | telegram-bot-ruby | 2.4.0 |
| **Database** | SQLite3 | 2.6.0 |
| **ORM** | Sequel | 5.91.0 |
| **Environment Config** | dotenv | 3.1.7 |

### Dependencies Tree

```
telegram-bot-ruby (2.4.0)
├── dry-struct (~> 1.6)
├── faraday (~> 2.0)
├── faraday-multipart (~> 1.0)
└── zeitwerk (~> 2.6)

sequel (5.91.0)
└── bigdecimal

sqlite3 (2.6.0-arm64-darwin)

dotenv (3.1.7)
```

### Database Schema

**Table: `orders`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | PRIMARY KEY | Auto-increment ID |
| `user_id` | Bignum | Telegram user ID |
| `username` | String | User's first name |
| `text` | String | Order description |
| `ready` | Boolean | Order status (default: false) |
| `created_at` | DateTime | Creation timestamp |

### Bot Features

- `/start` command - Greeting message
- Order creation - Users can send any text as an order
- Barista notification - New orders sent to barista's chat
- Inline keyboard buttons - "Заказ готов" button for barista
- Customer notification - Automatic notification when order is ready

---

## 2. Flutter Mobile App (Red Cup)

### Core Technologies

| Category | Technology | Version |
|----------|------------|---------|
| **Framework** | Flutter | SDK >=3.0.0 <4.0.0 |
| **Language** | Dart | - |
| **State Management** | flutter_bloc | 8.1.3 |
| **Navigation** | go_router | 13.0.0 |
| **HTTP Client** | dio | 5.4.0 |
| **Local Storage** | Hive, SharedPreferences, FlutterSecureStorage | - |

### Firebase Integration

- `firebase_core` (2.24.2)
- `firebase_auth` (4.15.3)
- `firebase_messaging` (14.7.9)
- `firebase_analytics` (10.7.4)
- `firebase_crashlytics` (3.4.9)

### Key Features (Planned)

- Google/Apple authentication
- QR code generation and scanning
- Google Maps integration
- Geolocation services
- Push notifications

---

## Architecture Diagram

```mermaid
graph TB
    subgraph Mobile App - Flutter
        A[Red Cup App]
        A --> B[Firebase Auth]
        A --> C[Local Storage - Hive]
        A --> D[Push Notifications]
    end

    subgraph Backend - Ruby
        E[Telegram Bot]
        E --> F[SQLite Database]
        E --> G[Telegram API]
    end

    subgraph External Services
        G[Telegram API]
        B[H[Firebase Services]]
    end

    Users --> E
    Barista --> E
    A -.->|Future Integration| E
```

---

## Current Limitations

1. **No API Layer** - Bot and mobile app are not connected
2. **SQLite** - Not suitable for production scaling
3. **No Authentication** - Bot relies on Telegram user IDs only
4. **No Order History** - Users cannot view past orders
5. **No Menu System** - Orders are free-text only
6. **Single Barista** - Only one barista chat ID supported
7. **No Payment Integration** - Cash only

---

## Potential Improvement Areas

1. **Backend API** - Create REST API for mobile app integration
2. **Database Migration** - Move to PostgreSQL for production
3. **Menu System** - Add structured menu with categories
4. **Multi-barista Support** - Support multiple coffee shop locations
5. **Order Status Tracking** - More granular status updates
6. **User Profiles** - Store preferences and order history
7. **Payment Gateway** - Integrate online payments
8. **Admin Panel** - Web interface for management
