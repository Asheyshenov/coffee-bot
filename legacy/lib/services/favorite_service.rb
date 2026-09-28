# frozen_string_literal: true

# FavoriteService
# Service for managing favorite orders
# Handles creation, validation, ordering from favorites

module CoffeeBot
  module Services
    class FavoriteService
      MAX_FAVORITES = 5
      
      # Get all favorites for a user
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Array<FavoriteOrder>] List of favorites
      def self.for_user(telegram_user_id)
        FavoriteOrder.for_user(telegram_user_id)
      end
      
      # Check if user can add more favorites
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Boolean] True if can add more
      def self.can_add_more?(telegram_user_id)
        FavoriteOrder.can_add_more?(telegram_user_id)
      end
      
      # Get count of favorites for a user
      #
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Integer] Count
      def self.count_for_user(telegram_user_id)
        FavoriteOrder.count_for_user(telegram_user_id)
      end
      
      # Create a favorite from an existing order
      #
      # @param order [Order] The order to create from
      # @param title [String, nil] Optional title
      # @return [Hash] Result with :success, :favorite, :error, :message
      def self.create_from_order(order, title: nil)
        telegram_user_id = order.telegram_user_id
        
        # Check limit
        unless FavoriteOrder.can_add_more?(telegram_user_id)
          return { success: false, error: "У вас уже сохранено #{MAX_FAVORITES} избранных заказов. Удалите один из существующих, чтобы добавить новый." }
        end
        
        # Create favorite
        favorite = FavoriteOrder.create_from_order(order, title: title)
        
        # Check for duplicate
        if favorite.duplicate_exists?
          favorite.destroy
          return { success: false, error: "Такой заказ уже есть в избранном" }
        end
        
        { success: true, favorite: favorite }
      rescue => e
        { success: false, error: e.message }
      end
      
      # Delete a favorite
      #
      # @param favorite_id [Integer] Favorite ID
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Hash] Result with :success, :error
      def self.delete(favorite_id, telegram_user_id)
        favorite = FavoriteOrder.find_for_user(favorite_id, telegram_user_id)
        
        unless favorite
          return { success: false, error: "Избранный заказ не найден" }
        end
        
        favorite.destroy
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end
      
      # Rename a favorite
      #
      # @param favorite_id [Integer] Favorite ID
      # @param telegram_user_id [Integer] Telegram user ID
      # @param new_title [String] New title
      # @return [Hash] Result with :success, :error
      def self.rename(favorite_id, telegram_user_id, new_title)
        favorite = FavoriteOrder.find_for_user(favorite_id, telegram_user_id)
        
        unless favorite
          return { success: false, error: "Избранный заказ не найден" }
        end
        
        favorite.update(title: new_title)
        { success: true }
      rescue => e
        { success: false, error: e.message }
      end
      
      # Validate items for reordering
      # Checks if all items are still available in menu
      #
      # @param favorite [FavoriteOrder] The favorite to validate
      # @return [Hash] Result with :valid, :unavailable_items, :available_items
      def self.validate_for_reorder(favorite)
        unavailable = []
        available = []
        
        favorite.favorite_order_items.each do |item|
          menu_item = MenuItem[item.menu_item_id]
          
          if menu_item && menu_item.is_available
            available << item
          else
            unavailable << item
          end
        end
        
        {
          valid: unavailable.empty?,
          unavailable_items: unavailable,
          available_items: available
        }
      end
      
      # Create draft from favorite for reordering
      #
      # @param favorite [FavoriteOrder] The favorite to create from
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Hash] Result with :success, :draft, :error, :unavailable_items
      def self.create_draft_from_favorite(favorite, telegram_user_id)
        # Validate items first
        validation = validate_for_reorder(favorite)
        
        unless validation[:valid]
          return { 
            success: false, 
            error: "Некоторые позиции из избранного сейчас недоступны",
            unavailable_items: validation[:unavailable_items]
          }
        end
        
        DB.transaction do
          # Clear existing draft
          Draft.clear(telegram_user_id)
          
          # Create new draft
          draft = Draft.get_or_create(telegram_user_id)
          
          # Add items
          validation[:available_items].each do |fav_item|
            menu_item = MenuItem[fav_item.menu_item_id]
            
            # Add to draft using correct API (MenuItem, size, qty)
            draft.add_item_with_size(menu_item, fav_item.size, fav_item.qty)
          end
          
          # Set comment if any
          if favorite.comment && favorite.comment != '-'
            draft.set_comment(favorite.comment)
          end
          
          # Mark favorite as used
          favorite.mark_used!
          
          { success: true, draft: draft }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      # Create draft for editing a favorite
      # This creates a draft but doesn't mark the favorite as used
      #
      # @param favorite [FavoriteOrder] The favorite to edit
      # @param telegram_user_id [Integer] Telegram user ID
      # @return [Hash] Result with :success, :draft, :error
      def self.create_draft_for_editing(favorite, telegram_user_id)
        DB.transaction do
          # Clear existing draft
          Draft.clear(telegram_user_id)
          
          # Create new draft
          draft = Draft.get_or_create(telegram_user_id)
          
          # Add items (only available ones)
          favorite.favorite_order_items.each do |fav_item|
            menu_item = MenuItem[fav_item.menu_item_id]
            next unless menu_item && menu_item.is_available
            
            # Add to draft using correct API (MenuItem, size, qty)
            draft.add_item_with_size(menu_item, fav_item.size, fav_item.qty)
          end
          
          # Set comment
          if favorite.comment && favorite.comment != '-'
            draft.set_comment(favorite.comment)
          end
          
          { success: true, draft: draft }
        end
      rescue => e
        { success: false, error: e.message }
      end
      
      # Update favorite from draft (after editing)
      #
      # @param favorite [FavoriteOrder] The favorite to update
      # @param draft [Draft] The draft with new items
      # @return [Hash] Result with :success, :error
      def self.update_from_draft(favorite, draft)
        DB.transaction do
          # Delete old items
          favorite.favorite_order_items.each(&:destroy)
          
          # Create new items from draft
          draft.items.each do |item|
            FavoriteOrderItem.create(
              favorite_order_id: favorite.id,
              menu_item_id: item['menu_item_id'],
              item_name_snapshot: item['name'],
              qty: item['qty'],
              size: item['size'],
              unit_price_snapshot: item['unit_price'],
              addons_json: item['addons']&.to_json
            )
          end
          
          # Update comment
          favorite.update(
            comment: draft.comment,
            updated_at: Time.now.utc
          )
          
          { success: true }
        end
      rescue => e
        { success: false, error: e.message }
      end
    end
  end
end
