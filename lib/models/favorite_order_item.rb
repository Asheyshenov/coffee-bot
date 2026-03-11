# frozen_string_literal: true

# FavoriteOrderItem Model
# Stores individual items within a favorite order template

class FavoriteOrderItem < Sequel::Model
  # Associations
  many_to_one :favorite_order, class: :FavoriteOrder
  
  # Validations
  def validate
    super
    errors.add(:menu_item_id, 'cannot be blank') if menu_item_id.nil?
    errors.add(:qty, 'must be positive') if qty.nil? || qty < 1
  end
  
  # Get addons as array
  #
  # @return [Array<Hash>] Array of addon hashes
  def addons
    return [] if addons_json.nil? || addons_json.empty?
    
    JSON.parse(addons_json)
  rescue JSON::ParserError
    []
  end
  
  # Set addons from array
  #
  # @param addons_array [Array<Hash>] Array of addon hashes
  def addons=(addons_array)
    self.addons_json = addons_array&.empty? ? nil : addons_array.to_json
  end
  
  # Check if the menu item is still available
  #
  # @return [Boolean] True if item is available
  def item_available?
    item = MenuItem[menu_item_id]
    item && item.is_available
  end
  
  # Get the current menu item
  #
  # @return [MenuItem, nil] The menu item or nil if not found
  def current_menu_item
    MenuItem[menu_item_id]
  end
  
  # Get current price from menu
  #
  # @return [Integer, nil] Current price in soms or nil if item not found
  def current_price
    item = current_menu_item
    return nil unless item
    
    if size && item.respond_to?(:price_for_size)
      item.price_for_size(size)
    else
      item.price
    end
  end
  
  # Format for display
  #
  # @return [String] Formatted string
  def format_display
    line = "#{item_name_snapshot}"
    line += " (#{size})" if size && !size.empty?
    line += " x#{qty}"
    line
  end
end
