class BasiqAccount::Processor
  include CurrencyNormalizable

  attr_reader :basiq_account

  def initialize(basiq_account)
    @basiq_account = basiq_account
  end

  def process
    unless basiq_account.current_account.present?
      Rails.logger.info "BasiqAccount::Processor - No linked account for basiq_account #{basiq_account.id}, skipping"
      return
    end

    process_account!
    process_transactions
  rescue => e
    Rails.logger.error "BasiqAccount::Processor - Failed to process account #{basiq_account.id}: #{e.message}"
    report_exception(e, "account")
    raise
  end

  private

    def process_account!
      account = basiq_account.current_account
      balance = basiq_account.current_balance || 0

      # BASIQ account balances for liabilities may arrive negative. Sure stores
      # liability balances as positive amounts owed.
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = balance.abs
      end

      currency = parse_currency(basiq_account.currency) || account.currency || "AUD"

      account.update!(
        balance: balance,
        cash_balance: balance,
        currency: currency
      )
    end

    def process_transactions
      BasiqAccount::Transactions::Processor.new(basiq_account).process
    rescue => e
      report_exception(e, "transactions")
    end

    def report_exception(error, context)
      Sentry.capture_exception(error) do |scope|
        scope.set_tags(
          basiq_account_id: basiq_account.id,
          context: context
        )
      end
    end
end
