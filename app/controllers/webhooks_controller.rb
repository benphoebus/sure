class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def plaid
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = Provider::Registry.plaid_provider_for_region(:us)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
  end

  def plaid_eu
    webhook_body = request.body.read
    plaid_verification_header = request.headers["Plaid-Verification"]

    client = Provider::Registry.plaid_provider_for_region(:eu)

    client.validate_webhook!(plaid_verification_header, webhook_body)

    PlaidItem::WebhookProcessor.new(webhook_body).process

    render json: { received: true }, status: :ok
  rescue => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
  end

  def basiq
    webhook_body = request.body.read
    payload = JSON.parse(webhook_body)

    user_id = payload.dig("data", "userId") ||
              payload.dig("data", "user", "id") ||
              payload["userId"] ||
              payload["user_id"] ||
              extract_basiq_id_from_url(payload.dig("links", "eventEntity"), "users")

    job_id = payload.dig("data", "jobId") ||
             payload.dig("data", "job", "id") ||
             payload["jobId"] ||
             payload["job_id"] ||
             extract_basiq_id_from_url(payload.dig("links", "eventEntity"), "jobs")

    if user_id.present?
      BasiqItem.where(basiq_user_id: user_id).find_each do |basiq_item|
        basiq_item.append_pending_job_ids!([ job_id ]) if job_id.present?
        basiq_item.sync_later unless basiq_item.syncing?
      end
    end

    render json: { received: true }, status: :ok
  rescue JSON::ParserError => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid JSON: #{error.message}" }, status: :bad_request
  rescue => error
    Sentry.capture_exception(error)
    render json: { error: "Invalid webhook: #{error.message}" }, status: :bad_request
  end

  def stripe
    stripe_provider = Provider::Registry.get_provider(:stripe)

    begin
      webhook_body = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

      stripe_provider.process_webhook_later(webhook_body, sig_header)

      head :ok
    rescue JSON::ParserError => error
      Sentry.capture_exception(error)
      Rails.logger.error "JSON parser error: #{error.message}"
      head :bad_request
    rescue Stripe::SignatureVerificationError => error
      Sentry.capture_exception(error)
      Rails.logger.error "Stripe signature verification error: #{error.message}"
      head :bad_request
    end
  end

  private

    def extract_basiq_id_from_url(url, collection)
      return nil if url.blank?

      uri = URI.parse(url)
      segments = uri.path.split("/")
      collection_index = segments.index(collection)
      return nil unless collection_index

      segments[collection_index + 1].presence
    rescue URI::InvalidURIError
      nil
    end
end
