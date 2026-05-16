# BASIQ integration runtime configuration
Rails.application.configure do
  truthy = %w[1 true yes on]
  falsy = %w[0 false no off]

  config.x.basiq ||= ActiveSupport::OrderedOptions.new

  config.x.basiq.environment = ENV.fetch("BASIQ_ENV", "sandbox")
  config.x.basiq.base_url = ENV.fetch("BASIQ_BASE_URL", "https://au-api.basiq.io")
  config.x.basiq.version = ENV.fetch("BASIQ_VERSION", "3.0")
  config.x.basiq.consent_url = ENV.fetch("BASIQ_CONSENT_URL", "https://consent.basiq.io/home")
  config.x.basiq.webhook_url = ENV["BASIQ_WEBHOOK_URL"]

  include_pending_env = ENV["BASIQ_INCLUDE_PENDING"].to_s.strip.downcase
  config.x.basiq.include_pending = include_pending_env.blank? ? true : !falsy.include?(include_pending_env)
  config.x.basiq.debug_raw = truthy.include?(ENV["BASIQ_DEBUG_RAW"].to_s.strip.downcase)

  config.x.basiq.job_poll_attempts = ENV.fetch("BASIQ_JOB_POLL_ATTEMPTS", "10").to_i
  config.x.basiq.job_poll_interval = ENV.fetch("BASIQ_JOB_POLL_INTERVAL", "2").to_f
end
