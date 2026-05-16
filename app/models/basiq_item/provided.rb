module BasiqItem::Provided
  extend ActiveSupport::Concern

  def basiq_provider
    return nil unless credentials_configured?

    Provider::BasiqAdapter.build_provider
  end
end
