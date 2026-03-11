# frozen_string_literal: true

# FavoriteOrder Model
# Stores user's favorite order templates for quick reordering
#
# Limit: Maximum 5 favorites per user

class FavoriteOrder < Sequel::Model
  plugin :timestamps, update_on_create: true
  
  # Associations
  one_to_many :favorite_order_items, class: :FavoriteOrderItem
  
  # Constants
  MAX_FAVORITES_PER_USER = 5
  
  # Validations
  def validate
    super
    errors.add(:telegram_user_id, 'cannot be blank') if telegram_user_id.nil?
    errors.add(:title, 'cannot be blank') if title.nil? || title.strip.empty?
    
    # Check limit
    if new? && self.class.count_for_user(telegram_user_id) >= MAX_FAVORITES_PER_USER
      errors.add(:base, "maximum #{MAX_FAVORITES_PER_USER} favorites allowed per user")
    end
  end
  
  # Get all favorites for a user
  #
  # @param telegram_user_id [Integer] Telegram user ID
  # @return [Array<FavoriteOrder>] List of favorites
  def self.for_user(telegram_user_id)
    where(telegram_user_id: telegram_user_id).order(:created_at).all
  end
  
  # Get count of favorites for a user
  #
  # @param telegram_user_id [Integer] Telegram user ID
  # @return [Integer] Count of favorites
  def self.count_for_user(telegram_user_id)
    where(telegram_user_id: telegram_user_id).count
  end
  
  # Check if user can add more favorites
  #
  # @param telegram_user_id [Integer] Telegram user ID
  # @return [Boolean] True if user can add more
  def self.can_add_more?(telegram_user_id)
    count_for_user(telegram_user_id) < MAX_FAVORITES_PER_USER
  end
  
  # Find a favorite by ID for a specific user
  #
  # @param id [Integer] Favorite ID
  # @param telegram_user_id [Integer] Telegram user ID
  # @return [FavoriteOrder, nil] The favorite or nil
  def self.find_for_user(id, telegram_user_id)
    where(id: id, telegram_user_id: telegram_user_id).first
  end
  
  # Create from an existing order
  #
  # @param order [Order] The order to create from
  # @param title [String] Optional title for the favorite
  # @return [FavoriteOrder] The created favorite
  def self.create_from_order(order, title: nil)
    DB.transaction do
      favorite = new(
        telegram_user_id: order.telegram_user_id,
        title: title || generate_title(order),
        comment: order.comment
      )
      favorite.save
      
      # Copy order items
      order.order_items.each do |item|
        FavoriteOrderItem.create(
          favorite_order_id: favorite.id,
          menu_item_id: item.menu_item_id,
          item_name_snapshot: item.item_name,
          qty: item.qty,
          size: item.size,
          unit_price_snapshot: item.unit_price,
          addons_json: item.addons_json,
          comment: item.comment
        )
      end
      
      favorite
    end
  end
  
  # Generate automatic title from order items
  #
  # @param order [Order] The order
  # @return [String] Generated title
  def self.generate_title(order)
    items = order.order_items
    
    if items.empty?
      return "Заказ ##{order.id}"
    end
    
    # Take first 2 items
    titles = items.first(2).map do |item|
      parts = [item.item_name]
      parts << "(#{item.size})" if item.size && !item.size.empty?
      parts.join ' '
    end
    
    title = titles.join(' + ')
    
    if items.length > 2
      title += " +#{items.length - 2}"
    end
    
    title
  end
  
  # Check if this favorite matches another (for duplicate detection)
  #
  # @param other_favorite [FavoriteOrder] Another favorite
  # @return [Boolean] True if they match
  def matches?(other_favorite)
    return false unless other_favorite
    
    # Compare items
    my_items = favorite_order_items.map { |i| [i.menu_item_id, i.qty, i.size] }.sort
    other_items = other_favorite.favorite_order_items.map { |i| [i.menu_item_id, i.qty, i.size] }.sort
    
    my_items == other_items
  end
  
  # Check if a similar favorite already exists for this user
  #
  # @return [Boolean] True if duplicate exists
  def duplicate_exists?
    self.class.for_user(telegram_user_id).any? do |fav|
      fav.id != id && matches?(fav)
    end
  end
  
  # Format for display
  #
  # @return [String] Formatted string
  def format_display
    items_text = favorite_order_items.map do |item|
      line = "#{item.item_name_snapshot}"
      line += " (#{item.size})" if item.size && !item.size.empty?
      line += " x#{item.qty}"
      line
    end.join(', ')
    
    "⭐ #{title}\n#{items_text}"
  end
  
  # Format short version for button
  #
  # @return [String] Short text
  def format_short
    items = favorite_order_items.first(2).map do |item|
      "#{item.item_name_snapshot}#{item.size ? " (#{item.size})" : ''}"
    end.join(' + ')
    
    items += " +#{favorite_order_items.length - 2}" if favorite_order_items.length > 2
    items
  end
  
  # Mark as used (update last_used_at)
  def mark_used!
    update(last_used_at: Time.now.utc)
  end
  
  # Get total price (from snapshots, for reference only)
  #
  # @return [Integer] Total in soms
  def total_snapshot
    favorite_order_items.sum { |i| i.unit_price_snapshot * i.qty }
  end
end
