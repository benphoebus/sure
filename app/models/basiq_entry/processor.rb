require "digest/md5"

class BasiqEntry::Processor
  include CurrencyNormalizable

  def initialize(basiq_transaction, basiq_account:)
    @basiq_transaction = basiq_transaction
    @basiq_account = basiq_account
  end

  def process
    unless account.present?
      Rails.logger.warn "BasiqEntry::Processor - No linked account for basiq_account #{basiq_account.id}, skipping transaction #{external_id}"
      return nil
    end

    import_adapter.import_transaction(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "basiq",
      merchant: merchant,
      notes: notes,
      extra: extra_metadata
    )
  end

  private

    attr_reader :basiq_transaction, :basiq_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      @account ||= basiq_account.current_account
    end

    def data
      @data ||= basiq_transaction.with_indifferent_access
    end

    def external_id
      id = data[:id].presence
      raise ArgumentError, "BASIQ transaction missing id: #{data.inspect}" unless id

      "basiq_#{id}"
    end

    def name
      data[:description].presence ||
        data[:cleanDescription].presence ||
        data.dig(:merchant, :businessName).presence ||
        I18n.t("transactions.unknown_name")
    end

    def notes
      parts = []
      parts << data[:category] if data[:category].present?
      parts << data[:subClass] if data[:subClass].present?
      parts << data[:reference] if data[:reference].present?
      parts.presence&.join(" | ")
    end

    def amount
      parsed_amount = case data[:amount]
      when String
        BigDecimal(data[:amount])
      when Numeric
        BigDecimal(data[:amount].to_s)
      else
        BigDecimal("0")
      end

      # BASIQ uses banking convention: expenses are negative and income is positive.
      # Sure's bank-sync transaction convention stores expenses as positive, so invert.
      -parsed_amount
    rescue ArgumentError => e
      Rails.logger.error "Failed to parse BASIQ transaction amount: #{data[:amount].inspect} - #{e.message}"
      raise
    end

    def currency
      parse_currency(data[:currency]) || basiq_account.currency || account&.currency || "AUD"
    end

    def date
      date_value = data[:postDate].presence || data[:transactionDate].presence || data[:date].presence

      case date_value
      when String
        Date.parse(date_value)
      when Integer, Float
        Time.at(date_value).to_date
      when Time, DateTime
        date_value.to_date
      when Date
        date_value
      else
        raise ArgumentError, "Invalid BASIQ transaction date: #{date_value.inspect}"
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse BASIQ transaction date '#{date_value}': #{e.message}")
      raise ArgumentError, "Unable to parse transaction date: #{date_value.inspect}"
    end

    def merchant
      merchant_name = data.dig(:merchant, :businessName).presence ||
                      data.dig(:merchant, :name).presence
      return nil unless merchant_name.present?

      merchant_name = merchant_name.to_s.strip
      return nil if merchant_name.blank?

      merchant_id = data.dig(:merchant, :id).presence || Digest::MD5.hexdigest(merchant_name.downcase)

      @merchant ||= import_adapter.find_or_create_merchant(
        provider_merchant_id: "basiq_merchant_#{merchant_id}",
        name: merchant_name,
        source: "basiq",
        website_url: data.dig(:merchant, :website),
        logo_url: data.dig(:merchant, :logo)
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "BasiqEntry::Processor - Failed to create merchant '#{merchant_name}': #{e.message}"
      nil
    end

    def extra_metadata
      {
        basiq: {
          pending: pending?,
          status: data[:status],
          connection_id: basiq_account.connection_id,
          account_id: basiq_account.account_id,
          transaction_date: data[:transactionDate],
          post_date: data[:postDate]
        }.compact
      }
    end

    def pending?
      ActiveModel::Type::Boolean.new.cast(data[:pending]) ||
        data[:status].to_s.casecmp("pending").zero?
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' in BASIQ transaction #{external_id}, falling back to account currency")
    end
end
