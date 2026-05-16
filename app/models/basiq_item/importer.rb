class BasiqItem::Importer
  attr_reader :basiq_item, :basiq_provider

  def initialize(basiq_item, basiq_provider:)
    @basiq_item = basiq_item
    @basiq_provider = basiq_provider
  end

  def import
    Rails.logger.info "BasiqItem::Importer - Starting import for item #{basiq_item.id}"

    completed_jobs = poll_pending_jobs
    connections_data = fetch_connections_data
    accounts_data = fetch_accounts_data

    basiq_item.upsert_basiq_snapshot!(
      accounts_snapshot: accounts_data,
      connections_snapshot: connections_data
    )

    accounts_updated = upsert_accounts(accounts_data)
    transactions_imported = fetch_transactions_for_linked_accounts

    {
      success: true,
      completed_jobs: completed_jobs.count,
      accounts_updated: accounts_updated,
      transactions_imported: transactions_imported
    }
  rescue Provider::Basiq::BasiqError => e
    handle_basiq_error(e)
    {
      success: false,
      error: e.message,
      accounts_updated: 0,
      transactions_imported: 0
    }
  end

  private

    def poll_pending_jobs
      job_ids = Array(basiq_item.pending_job_ids).map(&:to_s).reject(&:blank?)
      return [] if job_ids.empty?

      attempts = Rails.configuration.x.basiq.job_poll_attempts.to_i
      interval = Rails.configuration.x.basiq.job_poll_interval.to_f
      completed = []

      attempts.times do |attempt|
        remaining = job_ids - completed
        break if remaining.empty?

        remaining.each do |job_id|
          job = basiq_provider.get_job(job_id)
          completed << job_id if job_completed?(job)
          raise Provider::Basiq::BasiqError.new("BASIQ job #{job_id} failed", :job_failed) if job_failed?(job)
        end

        break if (job_ids - completed).empty?
        Kernel.sleep(interval) if interval.positive? && attempt < attempts - 1
      end

      basiq_item.clear_pending_job_ids!(completed) if completed.any?
      completed
    end

    def fetch_connections_data
      basiq_provider.get_connections(basiq_item.basiq_user_id)
    end

    def fetch_accounts_data
      accounts_data = basiq_provider.get_accounts(basiq_item.basiq_user_id)

      if Rails.configuration.x.basiq.debug_raw
        Rails.logger.debug "BASIQ accounts response: #{accounts_data.to_json}"
      end

      accounts_data
    end

    def upsert_accounts(accounts_data)
      accounts = Array(accounts_data[:data] || accounts_data["data"])
      updated = 0

      accounts.each do |account_data|
        snapshot = account_data.with_indifferent_access
        account_id = snapshot[:id].to_s
        next if account_id.blank?

        basiq_account = basiq_item.basiq_accounts.find_or_initialize_by(account_id: account_id)
        basiq_account.upsert_basiq_snapshot!(account_data)
        updated += 1
      rescue => e
        Rails.logger.error "BasiqItem::Importer - Failed to upsert account #{account_id}: #{e.class} - #{e.message}"
      end

      updated
    end

    def fetch_transactions_for_linked_accounts
      imported = 0

      basiq_item.basiq_accounts.joins(:account_provider).joins(:account).merge(Account.visible).find_each do |basiq_account|
        result = fetch_and_store_transactions(basiq_account)
        imported += result[:transactions_count] if result[:success]
      end

      imported
    end

    def fetch_and_store_transactions(basiq_account)
      transactions_data = basiq_provider.get_transactions(
        basiq_item.basiq_user_id,
        account_id: basiq_account.account_id
      )

      if Rails.configuration.x.basiq.debug_raw
        Rails.logger.debug "BASIQ transactions response for #{basiq_account.account_id}: #{transactions_data.to_json}"
      end

      transactions = Array(transactions_data[:data] || transactions_data["data"])
      transactions = transactions.reject { |tx| pending_transaction?(tx) } unless Rails.configuration.x.basiq.include_pending

      existing_transactions = basiq_account.raw_transactions_payload.to_a
      merged = merge_transactions(existing_transactions, transactions)
      basiq_account.upsert_basiq_transactions_snapshot!(merged)

      { success: true, transactions_count: transactions.count }
    rescue Provider::Basiq::BasiqError => e
      Rails.logger.error "BasiqItem::Importer - BASIQ transaction fetch failed for account #{basiq_account.account_id}: #{e.message}"
      { success: false, transactions_count: 0, error: e.message }
    end

    def merge_transactions(existing_transactions, incoming_transactions)
      by_id = {}

      existing_transactions.each do |tx|
        tx_data = tx.with_indifferent_access
        tx_id = tx_data[:id].presence
        by_id[tx_id] = tx if tx_id.present?
      end

      incoming_transactions.each do |tx|
        tx_data = tx.with_indifferent_access
        tx_id = tx_data[:id].presence
        next unless tx_id.present?

        by_id[tx_id] = tx
      end

      by_id.values
    end

    def pending_transaction?(transaction_data)
      data = transaction_data.with_indifferent_access
      ActiveModel::Type::Boolean.new.cast(data[:pending]) ||
        data[:status].to_s.casecmp("pending").zero?
    end

    def job_completed?(job)
      status = job.with_indifferent_access[:status].to_s.downcase
      %w[success completed complete finished].include?(status)
    end

    def job_failed?(job)
      status = job.with_indifferent_access[:status].to_s.downcase
      %w[failed error].include?(status)
    end

    def handle_basiq_error(error)
      if error.error_type.in?(%i[unauthorized access_forbidden not_found])
        basiq_item.update!(status: :requires_update)
      end

      Rails.logger.error "BasiqItem::Importer - BASIQ API error: #{error.message}"
    end
end
