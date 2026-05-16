class Provider::BasiqAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata
  include Provider::Configurable

  Provider::Factory.register("BasiqAccount", self)

  def self.supported_account_types
    %w[Depository CreditCard Loan]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_basiq?

    [ {
      key: "basiq",
      name: "BASIQ",
      description: "Connect to Australian banks via BASIQ",
      can_connect: true,
      regions: %w[au],
      external_redirect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.new_basiq_item_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_basiq_items_path(
          account_id: account_id
        )
      }
    } ]
  end

  configure do
    description <<~DESC
      Setup instructions:
      1. Visit the [BASIQ Dashboard](https://dashboard.basiq.io/) to get your API key
      2. Store the Base64 key only; do not include the `Basic` prefix
      3. Sandbox uses `https://au-api.basiq.io` and BASIQ API version `3.0`
    DESC

    field :api_key,
          label: "API Key",
          required: false,
          secret: true,
          env_key: "BASIQ_API_KEY",
          description: "Base64 BASIQ API key from the dashboard"

    field :environment,
          label: "Environment",
          required: false,
          env_key: "BASIQ_ENV",
          default: "sandbox",
          description: "BASIQ environment label used by this app"

    field :base_url,
          label: "Base URL",
          required: false,
          env_key: "BASIQ_BASE_URL",
          default: "https://au-api.basiq.io",
          description: "BASIQ API base URL"

    field :version,
          label: "API Version",
          required: false,
          env_key: "BASIQ_VERSION",
          default: "3.0",
          description: "BASIQ API version header"

    field :consent_url,
          label: "Consent URL",
          required: false,
          env_key: "BASIQ_CONSENT_URL",
          default: "https://consent.basiq.io/home",
          description: "BASIQ Consent UI URL"

    field :webhook_url,
          label: "Webhook URL",
          required: false,
          env_key: "BASIQ_WEBHOOK_URL",
          description: "Optional BASIQ webhook destination for sandbox inspection or production callbacks"

    configured_check { get_value(:api_key).present? }
  end

  def provider_name
    "basiq"
  end

  def self.build_provider
    api_key = config_value(:api_key).presence || ENV["BASIQ_API_KEY"]
    return nil if api_key.blank?

    Provider::Basiq.new(
      api_key: api_key,
      base_url: config_value(:base_url).presence || Rails.configuration.x.basiq.base_url,
      version: config_value(:version).presence || Rails.configuration.x.basiq.version
    )
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_basiq_item_path(item)
  end

  def item
    provider_account.basiq_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"] || metadata["website"]
    if domain.blank? && url.present?
      URI.parse(url).host&.gsub(/^www\./, "")
    else
      domain
    end
  rescue URI::InvalidURIError
    nil
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || metadata["institutionName"] || item&.institution_summary
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || metadata["website"]
  end

  def institution_color
    item&.institution_color
  end
end
