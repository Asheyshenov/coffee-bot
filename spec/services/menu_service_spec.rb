# frozen_string_literal: true

require "rails_helper"

RSpec.describe MenuService do
  describe ".seed_menu" do
    it "creates the default menu once" do
      expect(described_class.seed_menu(current_tenant)).to eq(MenuService::DEFAULT_MENU.size)
      expect(described_class.seed_menu(current_tenant)).to eq(0)

      expect(MenuItem.count).to eq(MenuService::DEFAULT_MENU.size)
      expect(described_class.categories).to contain_exactly("Кофе", "Чай", "Десерты", "Добавки")
      expect(described_class.items_by_category("☕ Кофе").map(&:name).first(3)).to eq(%w[Эспрессо Американо Капучино])
      expect(MenuItem.find_by(name: "Латте").formatted_prices).to eq("S 140 KGS | M 160 KGS | L 190 KGS")
    end

    it "seeds the given coffee shop, whatever the current tenant" do
      other = create_tenant(slug: "seeded-shop")

      described_class.seed_menu(other)

      expect(MenuItem.count).to eq(0)
      expect(ActsAsTenant.current_tenant).not_to eq(other)
      ActsAsTenant.with_tenant(other) { expect(MenuItem.count).to eq(MenuService::DEFAULT_MENU.size) }
    end

    it "works without a current tenant" do
      tenant = current_tenant
      ActsAsTenant.with_tenant(nil) { described_class.seed_menu(tenant) }

      expect(MenuItem.count).to eq(MenuService::DEFAULT_MENU.size)
    end
  end

  describe "queries" do
    let!(:latte) { MenuItem.create!(category: "☕ Кофе", name: "Латте", price: 15_000) }
    let!(:raf) { MenuItem.create!(category: "☕ Кофе", name: "Раф", price: 18_000, available: false) }
    let!(:croissant) { MenuItem.create!(category: "Десерты", name: "Круассан", price: 12_000) }

    it "items_by_category matches the category without emoji and hides unavailable items" do
      expect(described_class.items_by_category("Кофе")).to eq([ latte ])
      expect(described_class.items_by_category("кофе", available_only: false)).to eq([ latte, raf ])
      expect(described_class.items_by_category("🍰 Десерты")).to eq([ croissant ])
      expect(described_class.items_by_category("Чай")).to eq([])
    end

    it "popular_items ranks available items by orders" do
      draft = Draft.get_or_create(client_id)
      draft.add_item(croissant, 3)
      Order.create_from_draft(draft, Customer.create!(telegram_user_id: client_id))

      expect(described_class.popular_items).to eq([ croissant, latte ])
    end

    it "addons are empty without an add-ons category" do
      expect(described_class.addons).to eq([])
    end

    it "find_item finds also unavailable items of the shop only" do
      expect(described_class.find_item(raf.id)).to eq(raf)
      ActsAsTenant.with_tenant(create_tenant(slug: "other-menu")) { expect(described_class.find_item(raf.id)).to be_nil }
    end
  end
end
