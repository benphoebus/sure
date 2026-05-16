module Family::BasiqConnectable
  extend ActiveSupport::Concern

  included do
    has_many :basiq_items, dependent: :destroy
  end

  def can_connect_basiq?
    Provider::BasiqAdapter.configured?
  end

  def create_basiq_item!(email:, item_name: nil)
    provider = Provider::BasiqAdapter.build_provider
    raise StandardError.new("BASIQ provider is not configured") unless provider

    user = provider.create_user(email: email)

    basiq_items.create!(
      name: item_name || "BASIQ Connection",
      basiq_user_id: user[:id] || user["id"]
    )
  end

  def basiq_item_for_connection(email:)
    basiq_items.active.first || create_basiq_item!(email: email)
  end
end
