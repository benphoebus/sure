# frozen_string_literal: true

module BasiqItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    results = []

    basiq_accounts.find_each do |ba|
      links = AccountProvider.where(provider_type: "BasiqAccount", provider_id: ba.id).to_a
      link_ids = links.map(&:id)
      result = {
        basiq_account_id: ba.id,
        name: ba.name,
        provider_link_ids: link_ids
      }
      results << result

      next if dry_run

      begin
        ActiveRecord::Base.transaction do
          Holding.where(account_provider_id: link_ids).update_all(account_provider_id: nil) if link_ids.any?
          links.each(&:destroy!)
        end
      rescue => e
        Rails.logger.warn("BasiqItem Unlinker: failed to unlink account #{ba.id}: #{e.class} - #{e.message}")
        result[:error] = e.message
      end
    end

    results
  end
end
