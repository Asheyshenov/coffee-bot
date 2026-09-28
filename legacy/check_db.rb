require 'sequel'
DB = Sequel.sqlite('coffee.db')

# Проверим, есть ли таблица 'orders'
if DB.table_exists?(:orders)
  puts "Таблица 'orders' существует!"
else
  puts "Таблица 'orders' не существует!"
end