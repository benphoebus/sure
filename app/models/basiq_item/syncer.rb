class BasiqItem::Syncer
  include SyncStats::Collector

  attr_reader :basiq_item

  def initialize(basiq_item)
    @basiq_item = basiq_item
  end

  def perform_sync(sync)
    sync.update!(status_text: "Importing accounts from BASIQ...") if sync.respond_to?(:status_text)
    import_result = basiq_item.import_latest_basiq_data

    sync.update!(status_text: "Checking account configuration...") if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: basiq_item.basiq_accounts)

    linked_accounts = basiq_item.basiq_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    unlinked_accounts = basiq_item.basiq_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    if unlinked_accounts.any?
      basiq_item.update!(pending_account_setup: true)
      sync.update!(status_text: "#{unlinked_accounts.count} accounts need setup...") if sync.respond_to?(:status_text)
    else
      basiq_item.update!(pending_account_setup: false)
    end

    if linked_accounts.any?
      sync.update!(status_text: "Processing transactions...") if sync.respond_to?(:status_text)
      mark_import_started(sync)
      basiq_item.process_accounts

      sync.update!(status_text: "Calculating balances...") if sync.respond_to?(:status_text)
      basiq_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      account_ids = linked_accounts.includes(:account_provider).filter_map { |ba| ba.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "basiq")
    end

    collect_health_stats(sync, errors: import_result[:success] ? nil : [ { message: import_result[:error], category: "import_error" } ])
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  def perform_post_sync
    # no-op
  end
end
