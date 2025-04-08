require 'sequel'

DB = Sequel.sqlite('coffee.db')

DB.create_table? :orders do
  primary_key :id
  Bignum :user_id
  String :username
  String :text
  TrueClass :ready, default: false
  DateTime :created_at
end