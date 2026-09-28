# frozen_string_literal: true

module MiniApp
  # The customer's cart (the Draft shared with the chat bot)
  class CartPresenter
    # @param draft [Draft, nil] nil is an empty cart
    def initialize(draft)
      @draft = draft
    end

    def as_json(*)
      lines = @draft&.items || []
      {
        items: lines.each_with_index.map { |line, index| line_json(line, index) },
        total: lines.sum { |line| line["line_total"].to_i },
        count: lines.sum { |line| line["qty"].to_i },
        comment: @draft&.comment,
        max_qty_per_line: Draft::MAX_QTY_PER_LINE
      }
    end

    private

    def line_json(line, index)
      {
        index: index,
        menu_item_id: line["menu_item_id"],
        name: line["name"],
        display_name: line["display_name"] || line["name"],
        size: line["size"],
        qty: line["qty"].to_i,
        unit_price: line["unit_price"].to_i,
        line_total: line["line_total"].to_i
      }
    end
  end
end
