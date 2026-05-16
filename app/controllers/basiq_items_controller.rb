class BasiqItemsController < ApplicationController
  before_action :set_basiq_item, only: [ :destroy, :sync, :setup_accounts, :complete_account_setup, :new_connection ]
  skip_before_action :verify_authenticity_token, only: [ :callback ]

  TRUSTED_BASIQ_HOSTS = %w[
    basiq.io
    consent.basiq.io
    au-api.basiq.io
  ].freeze

  def new
    unless Provider::BasiqAdapter.configured?
      redirect_to settings_providers_path, alert: "Please configure BASIQ first."
      return
    end

    unless Current.user.basiq_profile_complete?
      redirect_to settings_profile_path, alert: missing_basiq_profile_message
      return
    end

    basiq_item = Current.family.basiq_item_for_connection(user: Current.user)
    Rails.logger.info("BASIQ consent start: basiq_item_id=#{basiq_item.id} basiq_user_id=#{basiq_item.basiq_user_id}") if Rails.configuration.x.basiq.debug_raw
    redirect_url = basiq_item.start_consent(action: "connect", state: basiq_item.id, user: Current.user)
    log_basiq_redirect(redirect_url, state: basiq_item.id)

    safe_redirect_to_basiq(
      redirect_url,
      fallback_path: accounts_path,
      fallback_alert: "Invalid BASIQ authorization URL received."
    )
  rescue Provider::Basiq::BasiqError => e
    Rails.logger.error "BASIQ authorization error: #{e.message}"
    redirect_to settings_providers_path, alert: "Failed to start BASIQ authorization: #{e.message}"
  rescue StandardError => e
    redirect_to settings_profile_path, alert: "Failed to start BASIQ authorization: #{e.message}"
  end

  def callback
    log_basiq_callback

    if params[:error].present?
      redirect_to accounts_path, alert: "BASIQ authorization failed: #{params[:error_description].presence || params[:error]}"
      return
    end

    basiq_item = basiq_item_from_callback

    unless basiq_item
      redirect_to accounts_path, alert: "BASIQ connection not found."
      return
    end

    job_ids = extract_job_ids
    basiq_item.append_pending_job_ids!(job_ids) if job_ids.any?
    basiq_item.sync_later

    redirect_to accounts_path, notice: "BASIQ connected. Accounts are syncing."
  end

  def destroy
    @basiq_item.unlink_all!(dry_run: false)
    @basiq_item.destroy_later
    redirect_to accounts_path, notice: "Scheduled BASIQ connection for deletion."
  end

  def sync
    @basiq_item.sync_later unless @basiq_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def new_connection
    unless Current.user.basiq_profile_complete?
      redirect_to settings_profile_path, alert: missing_basiq_profile_message
      return
    end

    @basiq_item.refresh_basiq_profile!(Current.user)
    Rails.logger.info("BASIQ consent start: basiq_item_id=#{@basiq_item.id} basiq_user_id=#{@basiq_item.basiq_user_id}") if Rails.configuration.x.basiq.debug_raw
    redirect_url = @basiq_item.start_consent(action: "connect", state: @basiq_item.id, user: Current.user)
    log_basiq_redirect(redirect_url, state: @basiq_item.id)

    safe_redirect_to_basiq(
      redirect_url,
      fallback_path: accounts_path,
      fallback_alert: "Invalid BASIQ authorization URL received."
    )
  rescue Provider::Basiq::BasiqError => e
    redirect_to accounts_path, alert: "Failed to start BASIQ authorization: #{e.message}"
  rescue StandardError => e
    redirect_to settings_profile_path, alert: "Failed to start BASIQ authorization: #{e.message}"
  end

  def setup_accounts
    @basiq_accounts = @basiq_item.basiq_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })

    @account_type_options = [
      [ "Skip this account", "skip" ],
      [ "Checking or Savings Account", "Depository" ],
      [ "Credit Card", "CreditCard" ],
      [ "Loan or Mortgage", "Loan" ],
      [ "Other Asset", "OtherAsset" ]
    ]

    @subtype_options = {
      "Depository" => {
        label: "Account Subtype:",
        options: Depository::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "CreditCard" => {
        label: "",
        options: [],
        message: "Credit cards will be set up as credit card accounts."
      },
      "Loan" => {
        label: "Loan Type:",
        options: Loan::SUBTYPES.map { |k, v| [ v[:long], k ] }
      },
      "OtherAsset" => {
        label: nil,
        options: [],
        message: "Other assets will be set up as general assets."
      }
    }

    render layout: false
  end

  def complete_account_setup
    account_types = params[:account_types] || {}
    account_subtypes = params[:account_subtypes] || {}

    @basiq_item.update!(sync_start_date: params[:sync_start_date]) if params[:sync_start_date].present?

    created_count = 0
    skipped_count = 0

    account_types.each do |basiq_account_id, selected_type|
      if selected_type == "skip" || selected_type.blank?
        skipped_count += 1
        next
      end

      basiq_account = @basiq_item.basiq_accounts.find(basiq_account_id)
      selected_subtype = account_subtypes[basiq_account_id]
      selected_subtype = "credit_card" if selected_type == "CreditCard" && selected_subtype.blank?

      account = Account.create_from_basiq_account(
        basiq_account,
        selected_type,
        selected_subtype
      )

      AccountProvider.create!(
        account: account,
        provider: basiq_account
      )

      created_count += 1
    end

    @basiq_item.update!(pending_account_setup: false)
    @basiq_item.sync_later if created_count.positive?

    if created_count.positive?
      flash[:notice] = "#{created_count} account(s) created successfully."
    elsif skipped_count.positive?
      flash[:notice] = "All BASIQ accounts were skipped."
    else
      flash[:notice] = "No BASIQ accounts to set up."
    end

    redirect_to accounts_path, status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    @available_basiq_accounts = Current.family.basiq_items
      .includes(:basiq_accounts)
      .flat_map(&:basiq_accounts)
      .reject { |ba| ba.account_provider.present? || ba.account.present? }
      .sort_by { |ba| ba.updated_at || ba.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    basiq_account = BasiqAccount.find(params[:basiq_account_id])

    if @account.account_providers.any? || @account.plaid_account_id.present? || @account.simplefin_account_id.present?
      redirect_to account_path(@account), alert: "Only manual accounts can be linked."
      return
    end

    unless basiq_account.basiq_item.present? && Current.family.basiq_items.include?(basiq_account.basiq_item)
      redirect_to account_path(@account), alert: "Invalid BASIQ account selected."
      return
    end

    AccountProvider.create!(
      account: @account,
      provider: basiq_account
    )

    redirect_to accounts_path, notice: "Account successfully linked to BASIQ.", status: :see_other
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_path(@account), alert: "Failed to link BASIQ account: #{e.message}"
  end

  private

    def set_basiq_item
      @basiq_item = Current.family.basiq_items.find(params[:id])
    end

    def missing_basiq_profile_message
      "BASIQ requires #{Current.user.basiq_profile_missing_fields.to_sentence} before linking an Australian bank."
    end

    def extract_job_ids
      raw = params[:jobIds].presence || params[:job_ids].presence || params[:jobId].presence || params[:job_id].presence || params[:jobs].presence
      case raw
      when Array
        raw
      when String
        raw.split(",")
      else
        []
      end.map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def basiq_item_from_callback
      return Current.family.basiq_items.find_by(id: params[:state]) if params[:state].present?

      active_items = Current.family.basiq_items.active.to_a
      active_items.first if active_items.one?
    end

    def valid_basiq_redirect_url?(url)
      return false if url.blank?

      uri = URI.parse(url)
      return false unless uri.scheme == "https"
      return false if uri.host.blank?

      TRUSTED_BASIQ_HOSTS.any? do |trusted_host|
        uri.host == trusted_host || uri.host.end_with?(".#{trusted_host}")
      end
    rescue URI::InvalidURIError => e
      Rails.logger.warn("BASIQ invalid redirect URL: #{url.inspect} - #{e.message}")
      false
    end

    def safe_redirect_to_basiq(redirect_url, fallback_path:, fallback_alert:)
      if valid_basiq_redirect_url?(redirect_url)
        redirect_to redirect_url, allow_other_host: true
      else
        redirect_to fallback_path, alert: fallback_alert
      end
    end

    def log_basiq_redirect(redirect_url, state:)
      return unless Rails.configuration.x.basiq.debug_raw

      uri = URI.parse(redirect_url)
      params = Rack::Utils.parse_nested_query(uri.query)
      params["token"] = "[FILTERED]" if params.key?("token")
      path = uri.host == "connect.basiq.io" ? "[FILTERED]" : uri.path

      Rails.logger.info(
        "BASIQ consent redirect: host=#{uri.host} path=#{path} state=#{state} params=#{params.inspect}"
      )
    rescue URI::InvalidURIError => e
      Rails.logger.warn("BASIQ consent redirect parse failed: #{e.message}")
    end

    def log_basiq_callback
      return unless Rails.configuration.x.basiq.debug_raw || params[:error].present?

      callback_params = params.to_unsafe_h.slice("state", "jobId", "jobIds", "error", "error_description")
      Rails.logger.info("BASIQ callback: #{callback_params.inspect}")
    end
end
