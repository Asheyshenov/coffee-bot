# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'MenuItem sizes functionality' do
  describe 'MenuItem with sizes' do
    before do
      @coffee = MenuItem.create(
        category: 'Кофе',
        name: 'Капучино',
        price: 15000,
        currency: 'KGS',
        sizes: { 'small' => 13000, 'medium' => 15000, 'large' => 18000 },
        default_size: 'medium'
      )
      
      @dessert = MenuItem.create(
        category: 'Десерты',
        name: 'Чизкейк',
        price: 20000,
        currency: 'KGS',
        sizes: nil,
        default_size: nil
      )
    end

    describe '#has_sizes?' do
      it 'returns true for items with sizes' do
        expect(@coffee.has_sizes?).to be true
      end

      it 'returns false for items without sizes' do
        expect(@dessert.has_sizes?).to be false
      end
    end

    describe '#drink?' do
      it 'returns true for coffee' do
        expect(@coffee.drink?).to be true
      end

      it 'returns false for desserts' do
        expect(@dessert.drink?).to be false
      end
    end

    describe '#price_for_size' do
      it 'returns correct price for small size' do
        expect(@coffee.price_for_size('small')).to eq(13000)
      end

      it 'returns correct price for medium size' do
        expect(@coffee.price_for_size('medium')).to eq(15000)
      end

      it 'returns correct price for large size' do
        expect(@coffee.price_for_size('large')).to eq(18000)
      end

      it 'returns default size price when size is nil' do
        expect(@coffee.price_for_size(nil)).to eq(15000) # medium is default
      end

      it 'returns base price for items without sizes' do
        expect(@dessert.price_for_size('small')).to eq(20000)
        expect(@dessert.price_for_size(nil)).to eq(20000)
      end
    end

    describe '#formatted_price_for_size' do
      it 'formats price with currency' do
        expect(@coffee.formatted_price_for_size('small')).to eq('130 KGS')
        expect(@coffee.formatted_price_for_size('large')).to eq('180 KGS')
      end
    end

    describe '#formatted_prices' do
      it 'shows all sizes for items with sizes' do
        expect(@coffee.formatted_prices).to eq('S 130 KGS | M 150 KGS | L 180 KGS')
      end

      it 'shows single price for items without sizes' do
        expect(@dessert.formatted_prices).to eq('200 KGS')
      end
    end

    describe '#size_options' do
      it 'returns array of size options' do
        options = @coffee.size_options
        expect(options).to be_an(Array)
        expect(options.length).to eq(3)
        expect(options.first).to include(size: 'small', label: 'S', price: 13000)
      end

      it 'returns empty array for items without sizes' do
        expect(@dessert.size_options).to eq([])
      end
    end
  end

  describe 'Draft with sizes' do
    before do
      @user_id = 12345
      @coffee = MenuItem.create(
        category: 'Кофе',
        name: 'Капучино',
        price: 15000,
        currency: 'KGS',
        sizes: { 'small' => 13000, 'medium' => 15000, 'large' => 18000 },
        default_size: 'medium'
      )
      @dessert = MenuItem.create(
        category: 'Десерты',
        name: 'Чизкейк',
        price: 20000,
        currency: 'KGS'
      )
      @draft = Draft.get_or_create(@user_id)
    end

    after do
      Draft.clear(@user_id)
    end

    describe '#add_item_with_size' do
      it 'adds item with size to cart' do
        @draft.add_item_with_size(@coffee, 'large', 2)
        
        items = @draft.items
        expect(items.length).to eq(1)
        expect(items.first['size']).to eq('large')
        expect(items.first['unit_price']).to eq(18000)
        expect(items.first['qty']).to eq(2)
        expect(items.first['display_name']).to eq('Капучино (L)')
      end

      it 'adds item without size to cart' do
        @draft.add_item_with_size(@dessert, nil, 1)
        
        items = @draft.items
        expect(items.length).to eq(1)
        expect(items.first['size']).to be_nil
        expect(items.first['unit_price']).to eq(20000)
        expect(items.first['display_name']).to eq('Чизкейк')
      end

      it 'groups same item with same size' do
        @draft.add_item_with_size(@coffee, 'medium', 1)
        @draft.add_item_with_size(@coffee, 'medium', 2)
        
        items = @draft.items
        expect(items.length).to eq(1)
        expect(items.first['qty']).to eq(3)
      end

      it 'keeps different sizes separate' do
        @draft.add_item_with_size(@coffee, 'small', 1)
        @draft.add_item_with_size(@coffee, 'large', 1)
        
        items = @draft.items
        expect(items.length).to eq(2)
      end
    end

    describe '#format_cart with sizes' do
      it 'displays items with size labels' do
        @draft.add_item_with_size(@coffee, 'large', 2)
        @draft.add_item_with_size(@dessert, nil, 1)
        
        cart = @draft.format_cart
        expect(cart).to include('Капучино (L)')
        expect(cart).to include('Чизкейк')
      end
    end
  end
end
