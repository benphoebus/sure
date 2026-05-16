class BasiqAccount::Transactions::Processor
  attr_reader :basiq_account

  def initialize(basiq_account)
    @basiq_account = basiq_account
  end

  def process
    unless basiq_account.raw_transactions_payload.present?
      Rails.logger.info "BasiqAccount::Transactions::Processor - No transactions for basiq_account #{basiq_account.id}"
      return { success: true, total: 0, imported: 0, failed: 0, errors: [] }
    end

    imported_count = 0
    failed_count = 0
    errors = []

    basiq_account.raw_transactions_payload.each_with_index do |transaction_data, index|
      begin
        result = BasiqEntry::Processor.new(
          transaction_data,
          basiq_account: basiq_account
        ).process

        if result.nil?
          failed_count += 1
          errors << { index: index, transaction_id: transaction_data[:id], error: "No linked account" }
        else
          imported_count += 1
        end
      rescue ArgumentError => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        Rails.logger.error "BasiqAccount::Transactions::Processor - Validation error for #{transaction_id}: #{e.message}"
        errors << { index: index, transaction_id: transaction_id, error: e.message }
      rescue => e
        failed_count += 1
        transaction_id = transaction_data.try(:[], :id) || transaction_data.try(:[], "id") || "unknown"
        Rails.logger.error "BasiqAccount::Transactions::Processor - Error processing #{transaction_id}: #{e.class} - #{e.message}"
        errors << { index: index, transaction_id: transaction_id, error: "#{e.class}: #{e.message}" }
      end
    end

    {
      success: failed_count.zero?,
      total: basiq_account.raw_transactions_payload.count,
      imported: imported_count,
      failed: failed_count,
      errors: errors
    }
  end
end
