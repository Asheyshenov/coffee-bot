# ☕ Coffee Bot

Production-ready Telegram bot для заказа кофе с интеграцией O!Деньги QRPay API.

## 🚀 Возможности

- **Заказ через Telegram** - Интерактивный мастер заказа с категориями и корзиной
- **Оплата через QRPay** - Генерация QR-кода для оплаты через O!Деньги
- **Панель баристы** - Управление очередью заказов (только для авторизованных)
- **Уведомления** - Автоматические уведомления клиентов о статусе заказа
- **Меню** - Гибкое управление меню с категориями

## 📋 Статусы заказа

```
NEW → INVOICE_CREATED → PAID → IN_PROGRESS → READY
                ↓           ↓
             EXPIRED    CANCELLED
```

## 🛠 Установка

### Требования

- Ruby 3.0+
- SQLite3 (разработка) или PostgreSQL (продакшн)
- Telegram Bot Token (от @BotFather)
- QRPay аккаунт (O!Деньги)

### Быстрый старт (SQLite)

1. **Клонируйте репозиторий**
   ```bash
   git clone https://github.com/your-repo/coffee-bot.git
   cd coffee-bot
   ```

2. **Установите зависимости**
   ```bash
   bundle install
   ```

3. **Создайте .env файл**
   ```bash
   cp .env.example .env
   # Отредактируйте .env с вашими настройками
   ```

4. **Запустите миграции**
   ```bash
   bundle exec sequel -m db/migrations sqlite://db/development.sqlite3
   ```

5. **Заполните меню (опционально)**
   ```ruby
   # В консоли Ruby:
   require_relative 'config/boot'
   require_relative 'lib/services/menu_service'
   CoffeeBot::Services::MenuService.seed_menu
   ```

6. **Запустите бота**
   ```bash
   ruby bin/bot
   ```

### С PostgreSQL (Docker)

1. **Настройте переменные окружения**
   ```bash
   # Создайте .env файл с настройками продакшн
   DATABASE_URL=postgres://coffee:password@postgres:5432/coffee_bot
   TELEGRAM_BOT_TOKEN=your_token
   BARISTA_WHITELIST=123456789,987654321
   QRPAY_MERCHANT_ID=your_merchant_id
   QRPAY_SECRET_KEY=your_secret_key
   PUBLIC_BASE_URL=https://your-domain.com
   ```

2. **Запустите через docker-compose**
   ```bash
   docker-compose up -d
   ```

## ⚙️ Конфигурация

### Обязательные переменные

| Переменная | Описание |
|------------|----------|
| `TELEGRAM_BOT_TOKEN` | Токен бота от @BotFather |
| `BARISTA_WHITELIST` | Telegram ID барист (через запятую) |
| `QRPAY_MERCHANT_ID` | ID мерчанта O!Деньги |
| `QRPAY_SECRET_KEY` | Секретный ключ для подписи |

### Опциональные переменные

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `DATABASE_URL` | `sqlite://db/development.sqlite3` | URL базы данных |
| `ORDER_EXPIRE_MINUTES` | `15` | Минуты до истечения счёта |
| `QRPAY_BASE_URL` | `https://api.odengi.kg` | URL API QRPay |
| `PUBLIC_BASE_URL` | `http://localhost:9292` | Публичный URL для callbacks |
| `QRPAY_TIMEOUT_SECONDS` | `30` | Таймаут запросов |
| `QRPAY_RETRY_COUNT` | `3` | Количество повторов |

## 🤖 Команды бота

### Клиентские команды

| Команда | Описание |
|---------|----------|
| `/start` | Начать работу с ботом |
| `/menu` | Посмотреть меню |
| `/order` | Сделать заказ |
| `/my_orders` | Мои заказы |
| `/cancel` | Отменить текущий заказ |
| `/help` | Справка |

### Команды баристы

| Команда | Описание |
|---------|----------|
| `/barista` | Открыть панель баристы |

## 👨‍🍳 Добавление баристы

1. Узнайте Telegram ID пользователя (через @userinfobot)
2. Добавьте ID в `BARISTA_WHITELIST` в .env:
   ```
   BARISTA_WHITELIST=123456789,987654321
   ```
3. Перезапустите бота

## 📝 Управление меню

### Через консоль Ruby

```ruby
require_relative 'config/boot'

# Создать категорию и товар
CoffeeBot::Services::MenuService.create_item(
  category: 'Кофе',
  name: 'Капучино',
  price: 15000  # 150.00 KGS (в тыйынах!)
)

# Скрыть товар
CoffeeBot::Services::MenuService.toggle_availability(1)

# Удалить товар
CoffeeBot::Services::MenuService.delete_item(1)

# Заполнить тестовое меню
CoffeeBot::Services::MenuService.seed_menu
```

### Через SQL

```sql
-- Добавить товар
INSERT INTO menu_items (category, name, price, currency, is_available)
VALUES ('Кофе', 'Латте', 16000, 'KGS', 1);

-- Скрыть товар
UPDATE menu_items SET is_available = 0 WHERE id = 1;
```

## 🧪 Тестирование QRPay (Sandbox)

1. Используйте sandbox URL в конфигурации:
   ```
   QRPAY_BASE_URL=https://sandbox-api.odengi.kg
   ```

2. Создайте заказ и получите тестовый счёт

3. Для симуляции оплаты используйте тестовые карты O!Деньги

4. Callback придёт на `/callbacks/odengi/qrpay/result`

## 📁 Структура проекта

```
coffee-bot/
├── bin/
│   ├── bot              # Точка входа Telegram бота
│   └── callback_app     # HTTP сервер для callbacks
├── config/
│   ├── boot.rb          # Загрузка конфигурации
│   └── database.rb      # Подключение к БД
├── db/
│   ├── migrations/      # Миграции Sequel
│   └── schema.rb        # Схема БД
├── lib/
│   ├── bot/
│   │   └── router.rb    # Диспетчер команд
│   ├── models/          # Sequel модели
│   ├── services/        # Бизнес-логика
│   │   ├── auth_service.rb
│   │   ├── menu_service.rb
│   │   ├── order_service.rb
│   │   ├── notifier.rb
│   │   └── qrpay/       # QRPay интеграция
│   ├── http/
│   │   └── callback_app.rb
│   └── jobs/            # Фоновые задачи
├── spec/                # Тесты RSpec
├── .env.example         # Пример конфигурации
├── docker-compose.yml
├── Dockerfile
└── Gemfile
```

## 🔧 Устранение неполадок

### Ошибка подписи QRPay

- Проверьте `QRPAY_SECRET_KEY`
- Убедитесь, что часовой пояс сервера корректный
- Проверьте порядок полей в подписи

### Дублирование callbacks

- Callbacks логируются в таблицу `callback_logs`
- Дубликаты автоматически определяются по `event_id` или `dedupe_key`

### Неизвестный invoice в callback

- Проверьте, что `merchantInvoiceId` совпадает с заказом
- Заказ должен быть в статусе `INVOICE_CREATED`

### Бот не отвечает

- Проверьте `TELEGRAM_BOT_TOKEN`
- Убедитесь, что бот запущен без ошибок
- Проверьте логи на наличие исключений

## 📊 Мониторинг

### Health check

```bash
curl http://localhost:9292/health
```

### Логи

Логи выводятся в JSON формате в продакшн:

```json
{"timestamp":"2024-01-15T10:30:00.000Z","level":"INFO","message":"Order created","order_id":123}
```

## 🧪 Запуск тестов

```bash
bundle exec rspec
```

## 📄 Лицензия

MIT License

## 🤝 Вклад в проект

1. Fork репозитория
2. Создайте ветку для фичи (`git checkout -b feature/amazing-feature`)
3. Commit изменения (`git commit -m 'Add amazing feature'`)
4. Push в ветку (`git push origin feature/amazing-feature`)
5. Откройте Pull Request
