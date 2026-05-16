class BasiqItem::SyncCompleteEvent
  attr_reader :basiq_item

  def initialize(basiq_item)
    @basiq_item = basiq_item
  end

  def broadcast
    basiq_item.accounts.each(&:broadcast_sync_complete)

    basiq_item.broadcast_replace_to(
      basiq_item.family,
      target: "basiq_item_#{basiq_item.id}",
      partial: "basiq_items/basiq_item",
      locals: { basiq_item: basiq_item }
    )

    basiq_item.family.broadcast_sync_complete
  end
end
