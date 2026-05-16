class BasiqItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :basiq_user_id, deterministic: true
    encrypts :pending_job_ids
    encrypts :raw_payload
    encrypts :raw_connections_payload
    encrypts :raw_institution_payload
  end

  belongs_to :family
  has_one_attached :logo

  has_many :basiq_accounts, dependent: :destroy
  has_many :accounts, through: :basiq_accounts

  validates :name, :basiq_user_id, presence: true
  validates :basiq_user_id, uniqueness: true

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def credentials_configured?
    Provider::BasiqAdapter.configured?
  end

  def start_consent(action: "connect", state: id)
    provider = basiq_provider
    raise StandardError.new("BASIQ provider is not configured") unless provider

    client_token = provider.client_access_token(user_id: basiq_user_id)
    provider.consent_url(client_token: client_token, state: state, action: action)
  end

  def import_latest_basiq_data
    provider = basiq_provider
    unless provider
      Rails.logger.error "BasiqItem #{id} - Cannot import: BASIQ provider is not configured"
      raise StandardError.new("BASIQ provider is not configured")
    end

    BasiqItem::Importer.new(self, basiq_provider: provider).import
  rescue => e
    Rails.logger.error "BasiqItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  def process_accounts
    return [] if basiq_accounts.empty?

    results = []
    basiq_accounts.joins(:account).merge(Account.visible).each do |basiq_account|
      begin
        result = BasiqAccount::Processor.new(basiq_account).process
        results << { basiq_account_id: basiq_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "BasiqItem #{id} - Failed to process account #{basiq_account.id}: #{e.message}"
        results << { basiq_account_id: basiq_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue => e
      Rails.logger.error "BasiqItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_basiq_snapshot!(accounts_snapshot:, connections_snapshot: nil)
    assign_attributes(
      raw_payload: accounts_snapshot,
      raw_connections_payload: connections_snapshot || raw_connections_payload
    )

    save!
  end

  def append_pending_job_ids!(job_ids)
    cleaned = Array(job_ids).flatten.compact.map(&:to_s).reject(&:blank?)
    return if cleaned.empty?

    update!(pending_job_ids: (Array(pending_job_ids) + cleaned).uniq)
  end

  def clear_pending_job_ids!(job_ids)
    remove_ids = Array(job_ids).map(&:to_s)
    update!(pending_job_ids: Array(pending_job_ids).map(&:to_s) - remove_ids)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def linked_accounts_count
    basiq_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    basiq_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    basiq_accounts.count
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts.zero?
      "No accounts found"
    elsif unlinked_count.zero?
      "#{linked_count} #{'account'.pluralize(linked_count)} synced"
    else
      "#{linked_count} synced, #{unlinked_count} need setup"
    end
  end

  def institution_display_name
    institution_summary
  end

  def connected_institutions
    basiq_accounts.where.not(institution_metadata: nil)
                  .map(&:institution_metadata)
                  .uniq { |metadata| metadata["id"] || metadata["name"] || metadata["institutionName"] }
  end

  def institution_summary
    institutions = connected_institutions

    case institutions.count
    when 0
      name
    when 1
      institutions.first["name"] || institutions.first["institutionName"] || "1 institution"
    else
      "#{institutions.count} institutions"
    end
  end

  def institution_color
    "#22C55E"
  end
end
