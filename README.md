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

- Ruby 3.2 + Bundler
- SQLite3 (разработка) или PostgreSQL (продакшн)
- Telegram Bot Token (от @BotFather)
- Аккаунт MWallet (O!Деньги): SID и пароль сервиса
- Для продакшна: Docker с Compose v2 (`docker compose`)

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

4. **Примените миграции**
   ```bash
   bundle exec ruby bin/migrate
   ```
   В development (`RACK_ENV=development`) миграции дополнительно применяются
   автоматически при старте. В любом другом окружении их нужно запускать
   только через `bin/migrate`.

5. **Заполните меню (опционально)**
   ```ruby
   # В консоли Ruby:
   require_relative 'config/boot'
   require_relative 'lib/services/menu_service'
   CoffeeBot::Services::MenuService.seed_menu
   ```

6. **Запустите бота и сервер callbacks**
   ```bash
   bundle exec ruby bin/bot            # бот + фоновые задачи StatusSyncer и InvoiceExpirer
   bundle exec ruby bin/callback_app   # Puma на порту PORT (по умолчанию 9292)
   ```
   Локально сервер callbacks слушает только `localhost`. Чтобы MWallet мог до него
   достучаться, поднимите туннель (например, `cloudflared tunnel --url http://localhost:9292`)
   и укажите его адрес в `PUBLIC_BASE_URL`.

### Продакшн (Docker Compose + PostgreSQL)

1. **Настройте .env** рядом с `docker-compose.yml`
   ```bash
   cp .env.example .env
   ```
   Обязательно заполните (без них `docker compose` сразу завершится с ошибкой):
   ```bash
   POSTGRES_PASSWORD=...        # только буквы и цифры: пароль подставляется в DATABASE_URL
   TELEGRAM_BOT_TOKEN=...
   BARISTA_WHITELIST=123456789,987654321
   MWALLET_SID=...
   MWALLET_PASSWORD='...'
   PUBLIC_BASE_URL=https://your-domain.com
   MWALLET_TEST_MODE=false      # для реальных платежей (по умолчанию true, песочница)
   ```
   `DATABASE_URL` и `RACK_ENV=production` compose задаёт сам.

2. **Соберите образ и запустите**
   ```bash
   docker compose up -d --build
   ```
   Порядок запуска:
   - `postgres` стартует и проходит healthcheck;
   - одноразовый сервис `migrate` выполняет `bin/migrate` и завершается;
   - `bot` и `callback` стартуют только после успешных миграций, поэтому
     не соревнуются между собой за миграции. Если миграция упала, они не запустятся:
     смотрите `docker compose logs migrate`.

   Миграции выполняются при каждом `docker compose up`. Запустить их вручную:
   ```bash
   docker compose run --rm migrate
   ```

3. **Настройте HTTPS.** Сервер callbacks (Puma) слушает `0.0.0.0:9292` внутри контейнера,
   порт 9292 опубликован на хосте. Поставьте перед ним reverse proxy с TLS (nginx, Caddy)
   или туннель и укажите внешний адрес в `PUBLIC_BASE_URL`. MWallet отправляет callbacks
   на `PUBLIC_BASE_URL/callbacks/mwallet/result`. В production сервер принимает
   запросы только с хостом из `PUBLIC_BASE_URL`: proxy должен передавать исходный
   заголовок `Host`.

4. **База данных** наружу не публикуется: она доступна только контейнерам этого стека.
   ```bash
   docker compose exec postgres psql -U coffee coffee_bot
   ```
   Если нужен доступ с хоста, раскомментируйте в `docker-compose.yml`
   `ports: "127.0.0.1:5432:5432"` (только loopback).

Образ собирается без `vendor/`, `.bundle/`, `.env` и локальных баз SQLite
в любых каталогах, включая `db/development.sqlite3` (см. `.dockerignore`).
Если такой файл всё же попадёт в контекст сборки, `docker build` завершится
с ошибкой. Гемы ставятся в `/usr/local/bundle` внутри образа.

В `.dockerignore` шаблон сопоставляется с корнем контекста: `*.db` исключает
только `./coffee.db`, но не `db/coffee.db`. Для файлов в подкаталогах нужен
префикс `**/`.

## ⚙️ Конфигурация

### Обязательные переменные

| Переменная | Описание |
|------------|----------|
| `TELEGRAM_BOT_TOKEN` | Токен бота от @BotFather |
| `BARISTA_WHITELIST` | Telegram ID барист (через запятую) |
| `MWALLET_SID` | ID сервиса MWallet |
| `MWALLET_PASSWORD` | Пароль сервиса MWallet (подпись запросов и callbacks) |
| `PUBLIC_BASE_URL` | Публичный HTTPS-адрес сервера callbacks (обязателен в продакшне) |
| `POSTGRES_PASSWORD` | Пароль PostgreSQL (только для docker-compose) |

### Опциональные переменные

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `DATABASE_URL` | `sqlite://db/development.sqlite3` | URL базы данных (в docker-compose задаётся автоматически) |
| `RACK_ENV` | `development` | Окружение; в docker-compose `production` |
| `PORT` | `9292` | Порт сервера callbacks (`bin/callback_app`) |
| `ORDER_EXPIRE_MINUTES` | `15` | Минуты до истечения неоплаченного счёта |
| `MWALLET_BASE_URL` | `https://mw-api-test.dengi.kg/api/json/json.php` | URL API MWallet |
| `MWALLET_TEST_MODE` | `true` | Тестовые счета; `false` для реальных платежей |
| `MWALLET_API_VERSION` | `1005` | Версия API MWallet |
| `MWALLET_TIMEOUT_SECONDS` | `30` | Таймаут запросов к MWallet |
| `MWALLET_RETRY_COUNT` | `3` | Количество повторов при сетевых ошибках |
| `TUNNEL_HOSTS` | `.trycloudflare.com` | Разрешённые хосты туннелей (только development) |

### Фоновые задачи

Задачи запускаются внутри `bin/bot`:

- **StatusSyncer** (каждые 2 с) опрашивает MWallet по неоплаченным счетам на случай,
  если callback не дошёл.
- **InvoiceExpirer** (каждые 60 с) обрабатывает счета старше `ORDER_EXPIRE_MINUTES`.
  Сначала ещё раз проверяет оплату: если счёт оплачен, заказ уходит баристам.
  Иначе отменяет счёт в MWallet, переводит заказ в `EXPIRED` и сообщает клиенту.

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
│   ├── bot              # Точка входа Telegram бота (+ фоновые задачи)
│   ├── callback_app     # HTTP сервер для callbacks (Puma, PORT)
│   └── migrate          # Применение миграций БД
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
│   └── jobs/            # Фоновые задачи (StatusSyncer, InvoiceExpirer)
├── spec/                # Тесты RSpec
├── .env.example         # Пример конфигурации
├── .dockerignore        # Что не попадает в Docker-образ
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
# development
curl http://localhost:9292/health

# production: разрешён только хост из PUBLIC_BASE_URL
curl https://your-domain.com/health
curl -H "Host: your-domain.com" http://localhost:9292/health   # с сервера, в обход proxy
```

В docker-compose у сервиса `callback` настроен healthcheck по `/health`
(`docker compose ps` показывает `healthy`).

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
