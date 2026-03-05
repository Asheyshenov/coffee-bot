# Red Cup - Мобильное приложение для Giraffe Coffee

Мобильное приложение для сети кофеен Giraffe Coffee на Flutter.

## Архитектура

Проект использует Clean Architecture с разделением на слои:

- **Presentation** - UI слой (BLoC, виджеты, экраны)
- **Domain** - Бизнес-логика (entities, use cases, repositories interfaces)
- **Data** - Реализация репозиториев, API клиенты, локальное хранилище

## Структура проекта

```
lib/
├── core/              # Общие компоненты
│   ├── constants/     # Константы
│   ├── errors/        # Обработка ошибок
│   ├── network/       # Настройка сети
│   ├── theme/         # Темы приложения
│   └── utils/         # Утилиты
├── features/          # Функциональные модули
│   ├── auth/          # Авторизация
│   ├── dashboard/     # Главный экран
│   ├── loyalty/       # Программа лояльности
│   ├── stamps/        # Пунш-карта
│   ├── branches/      # Филиалы
│   ├── news/          # Новости и акции
│   ├── orders/        # Заказы
│   ├── profile/       # Профиль
│   └── reviews/       # Отзывы
└── main.dart         # Точка входа
```

## Установка

1. Установите Flutter SDK
2. Установите зависимости:
```bash
flutter pub get
```

3. Запустите генерацию кода:
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

## Запуск

```bash
flutter run
```

## Тестирование

```bash
flutter test
```
