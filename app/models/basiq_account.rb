class BasiqAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :basiq_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :account_id, :currency, presence: true
  validates :account_id, uniqueness: { scope: :basiq_item_id }

  def current_account
    account
  end

  def account_type_display
    case account_type.to_s.downcase
    when "transaction", "savings"
      "Bank account"
    when "credit-card", "credit_card", "card"
      "Credit card"
    when "loan", "mortgage"
      "Loan"
    else
      account_type.to_s.titleize.presence || "Account"
    end
  end

  def upsert_basiq_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    assign_attributes(
      name: build_account_name(snapshot),
      account_id: snapshot[:id].to_s,
      connection_id: extract_connection_id(snapshot),
      institution_id: extract_institution_id(snapshot),
      currency: parse_currency(snapshot[:currency]) || "AUD",
      current_balance: parse_decimal(snapshot[:balance]),
      available_balance: parse_decimal(snapshot[:availableFunds] || snapshot[:available_funds]),
      account_status: snapshot[:status],
      account_type: extract_account_type(snapshot),
      account_subtype: extract_account_product(snapshot),
      provider: "basiq",
      masked_number: snapshot[:accountNo] || snapshot[:account_number],
      institution_metadata: extract_institution_metadata(snapshot),
      raw_payload: account_snapshot
    )

    save!
  end

  def upsert_basiq_transactions_snapshot!(transactions_snapshot)
    assign_attributes(raw_transactions_payload: transactions_snapshot)
    save!
  end

  private

    def build_account_name(snapshot)
      institution_name = extract_institution_metadata(snapshot)["name"]
      account_name = snapshot[:name].presence || snapshot[:accountHolder].presence || "BASIQ Account"

      if institution_name.present? && !account_name.to_s.downcase.include?(institution_name.to_s.downcase)
        "#{institution_name} - #{account_name}"
      else
        account_name
      end
    end

    def extract_connection_id(snapshot)
      connection = snapshot[:connection]
      if connection.is_a?(Hash)
        connection[:id] || connection["id"]
      elsif connection.present?
        connection
      else
        snapshot[:connectionId] || snapshot[:connection_id]
      end
    end

    def extract_institution_id(snapshot)
      institution = snapshot[:institution]
      return institution[:id] || institution["id"] if institution.is_a?(Hash)
      return institution if institution.present?

      snapshot[:institutionId] || snapshot[:institution_id]
    end

    def extract_account_type(snapshot)
      account_class = snapshot[:class]
      if account_class.is_a?(Hash)
        account_class[:type] || account_class["type"]
      else
        account_class || snapshot[:accountType] || snapshot[:account_type] || snapshot[:type]
      end
    end

    def extract_account_product(snapshot)
      account_class = snapshot[:class]
      if account_class.is_a?(Hash)
        account_class[:product] || account_class["product"]
      else
        snapshot[:product]
      end
    end

    def extract_institution_metadata(snapshot)
      institution = snapshot[:institution]
      metadata = institution.is_a?(Hash) ? institution.with_indifferent_access.to_h : {}

      metadata = metadata.merge(
        "id" => extract_institution_id(snapshot),
        "name" => snapshot[:institutionName] || snapshot[:institution_name],
        "connection_id" => extract_connection_id(snapshot)
      ).compact

      metadata
    end

    def parse_decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for BASIQ account #{id}, defaulting to AUD")
    end
end
