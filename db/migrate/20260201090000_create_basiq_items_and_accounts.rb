class CreateBasiqItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :basiq_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false

      t.string :basiq_user_id, null: false
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.date :sync_start_date

      t.jsonb :pending_job_ids, default: [], null: false
      t.jsonb :raw_payload
      t.jsonb :raw_connections_payload
      t.jsonb :raw_institution_payload

      t.timestamps
    end

    add_index :basiq_items, :basiq_user_id, unique: true
    add_index :basiq_items, :status

    create_table :basiq_accounts, id: :uuid do |t|
      t.references :basiq_item, null: false, foreign_key: true, type: :uuid

      t.string :name, null: false
      t.string :account_id, null: false
      t.string :connection_id
      t.string :institution_id
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.decimal :available_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :account_subtype
      t.string :provider
      t.string :masked_number

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :basiq_accounts, [ :basiq_item_id, :account_id ], unique: true
    add_index :basiq_accounts, :connection_id
    add_index :basiq_accounts, :institution_id
  end
end
