# Coffee Bot

Telegram-бот для заказа кофе с оплатой по QR через O!Деньги (MWallet). Сервис
мультиарендный (SaaS): у каждой кофейни свой Telegram-бот, свой мерчант-аккаунт
O!Деньги, своё меню и свой персонал. Деньги поступают напрямую на договор кофейни.

Старое приложение на Sinatra (одна кофейня, long polling) лежит в `legacy/` только
для справки. Целевая архитектура и план перехода описаны в `plans/saas-architecture.md`.

## Архитектура

- Rails 8.1 + PostgreSQL. База одна: данные, очередь задач (Solid Queue), кэш (Solid Cache), Action Cable (Solid Cable).
- Входящие запросы: `POST /tg/:bot_id` (webhook Telegram, проверяется `X-Telegram-Bot-Api-Secret-Token`), `POST /pay/mwallet/:payment_account_id` (callback O!Деньги), `GET /up` (health check).
- Обработчики только ставят задачи. Всё, что ходит во внешние API (сообщения, опрос оплат, истечение счетов), выполняют задачи Solid Queue.
- Кофейня (`Tenant`) определяется по боту или платёжному аккаунту из URL. `acts_as_tenant` с `require_tenant` не пропускает запрос без арендатора.
- Токены ботов и пароли MWallet хранятся зашифрованными (Active Record Encryption, ключи из ENV).

## Локальный запуск

Нужны Ruby из `.ruby-version` и PostgreSQL 16. Текущему пользователю ОС нужен доступ к
Postgres с правом создавать базы (`createuser -s $USER`).

```bash
bin/setup   # гемы, .env из .env.example, ключи шифрования, БД, демо-кофейня; затем bin/dev
bin/dev     # web на :3000 + сборка Tailwind + обработчик задач (bin/jobs), см. Procfile.dev
```

`bin/setup` сам создаёт `.env` и заполняет пустые `ACTIVE_RECORD_ENCRYPTION_*`. Готовые
значения он не трогает и не печатает. Остальные переменные описаны в `.env.example`.
`db/seeds.rb` создаёт кофейню `demo` с фейковыми токеном и паролем, поэтому с Telegram она
не работает. Для живого теста подключите свой тестовый бот, как описано ниже.

### Webhooks локально

Telegram и O!Деньги обращаются только к публичному HTTPS-адресу, поэтому нужен туннель:

```bash
cloudflared tunnel --url http://localhost:3000   # или: ngrok http 3000
```

Пропишите адрес туннеля в `.env` и перезапустите `bin/dev`:

```bash
PUBLIC_BASE_URL=https://xxxx.trycloudflare.com
RAILS_DEVELOPMENT_HOSTS=.trycloudflare.com,.ngrok-free.app
```

Затем заново выполните `tenants:connect_bot`, чтобы Telegram получил новый адрес webhook.
Адрес быстрого туннеля меняется при каждом запуске.

## Подключение кофейни

До появления админки кофейни подключаются rake-задачами. Любую задачу можно запускать
повторно: результат не изменится. Секреты задачи не печатают. Аргументы берите в кавычки
(zsh), запятые внутри аргументов не поддерживаются. В Docker перед командой добавьте
`docker compose exec app`.

Что нужно от владельца кофейни:
- токен бота, созданного в @BotFather;
- SID и пароль сервиса MWallet по договору кофейни с O!Деньги;
- Telegram ID сотрудников (узнать можно у @userinfobot).

```bash
bin/rails "tenants:create[corner,Кофейня на углу]"              # slug: латиница, цифры, дефис
bin/rails "tenants:connect_mwallet[corner,SID,PASSWORD,true]"   # true: тестовый API, false: боевой
bin/rails "tenants:add_staff[corner,123456789,owner]"           # роли: owner, manager, barista (по умолчанию)
bin/rails "tenants:add_staff[corner,987654321]"
bin/rails "tenants:seed_menu[corner]"                           # стандартное меню, если меню пустое
bin/rails "tenants:connect_bot[corner,123456:ABC-DEF]"          # последним шагом: после него бот принимает заказы
bin/rails tenants:list                                          # статус, бот, SID (маскирован), персонал, открытые заказы
bin/rails "tenants:remove_staff[corner,987654321]"              # отключить сотрудника (add_staff вернёт его)
```

- Для `connect_bot` адрес `PUBLIC_BASE_URL` должен быть публичным HTTPS: задача вызывает `getMe` и `setWebhook`.
- Боевой режим MWallet (`false`) требует `MWALLET_PRODUCTION_BASE_URL`. Точный URL боевого API нужно подтвердить у O!Деньги.
- При смене SID старый аккаунт отключается, но не удаляется: его заказы и callback'и продолжают работать.
- Чтобы токен не попал в историю shell, прочитайте его в переменную: `read -rs TOKEN`, затем `bin/rails "tenants:connect_bot[corner,$TOKEN]"`.

### Перенос текущей кофейни из legacy

1. Остановите старого бота: webhook и polling одного бота одновременно работать не могут. Старый callback-сервер оставьте, пока не оплачены или не истекли открытые счета.
2. Положите в `.env` старые переменные: `TELEGRAM_BOT_TOKEN`, `MWALLET_SID`, `MWALLET_PASSWORD`, `MWALLET_TEST_MODE`, `BARISTA_WHITELIST`, `ORDER_EXPIRE_MINUTES`. Затем выполните:
   ```bash
   bin/rails "tenants:import_legacy_env[main,Название кофейни]"
   bin/rails "tenants:seed_menu[main]"
   ```
   Задача создаёт кофейню, её MWallet-аккаунт и барист, а бота подключает последним. Заказы и меню старой базы не переносятся.
3. Удалите старые переменные из `.env`: приложение их не читает.

## Деплой (docker compose)

Нужен сервер с Docker Compose v2 и домен с HTTPS. HTTPS можно обеспечить reverse proxy
(Caddy или nginx) на `127.0.0.1:3000`, туннелем cloudflared или самим Thruster
(`TLS_DOMAIN`, порты 80 и 443, см. комментарии в `docker-compose.yml`).

```bash
cp .env.example .env    # PUBLIC_BASE_URL, POSTGRES_PASSWORD, ACTIVE_RECORD_ENCRYPTION_*,
                        # RAILS_MASTER_KEY, MWALLET_PRODUCTION_BASE_URL
docker compose up -d --build
docker compose ps                      # app: healthy
docker compose logs -f app
docker compose exec app bin/rails tenants:list
```

- Контейнеров два: `postgres` (порт наружу не открыт) и `app`. При старте `app` выполняет `db:prepare`, то есть создаёт базу или применяет миграции. Задачи Solid Queue работают внутри Puma (`SOLID_QUEUE_IN_PUMA=true`).
- Обновление: `git pull && docker compose up -d --build`.
- Бэкап: `docker compose exec postgres pg_dump -U coffee coffee_bot | gzip > backup-$(date +%F).sql.gz`. Ключи `ACTIVE_RECORD_ENCRYPTION_*` храните отдельно: без них сохранённые токены и пароли не расшифровать.
- Когда кофеен станет больше, вынесите задачи в отдельный контейнер (`bin/jobs`, `SOLID_QUEUE_IN_PUMA=false`) и проверьте `DB_POOL`.
- Kamal (гем в Gemfile) пока не настроен (`config/deploy.yml` нет). Основной способ деплоя — docker compose.

## Тесты

```bash
RAILS_ENV=test bin/rails db:prepare                        # один раз: база coffee_bot_test
bundle exec rspec
RAILS_ENV=test TEST_ENV_NUMBER=_mine bin/rails db:prepare  # своя база coffee_bot_test_mine
TEST_ENV_NUMBER=_mine bundle exec rspec                    # для параллельных прогонов
bin/rubocop && bin/brakeman
```

Сеть в тестах отключена, Telegram подменяется фейком. Каждый пример выполняется внутри
своей кофейни (`spec/support/tenancy.rb`). CI (`.github/workflows/ci.yml`) запускает
RuboCop, Brakeman, bundler-audit, importmap audit, RSpec на Postgres 16 и сборку Docker-образа.
