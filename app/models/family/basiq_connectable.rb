module Family::BasiqConnectable
  extend ActiveSupport::Concern

  included do
    has_many :basiq_items, dependent: :destroy
  end

  def can_connect_basiq?
    Provider::BasiqAdapter.configured?
  end

  def create_basiq_item!(user:, item_name: nil)
    provider = Provider::BasiqAdapter.build_provider
    raise StandardError.new("BASIQ provider is not configured") unless provider
    raise StandardError.new("BASIQ requires #{user.basiq_profile_missing_fields.to_sentence}") unless user.basiq_profile_complete?

    basiq_user = provider.create_user(profile: user.basiq_profile_payload)

    basiq_items.create!(
      name: item_name || "BASIQ Connection",
      basiq_user_id: basiq_user[:id] || basiq_user["id"]
    )
  end

  def basiq_item_for_connection(user:)
    basiq_item = basiq_items.active.first || create_basiq_item!(user: user)
    basiq_item.refresh_basiq_profile!(user)
    basiq_item
  end
end
