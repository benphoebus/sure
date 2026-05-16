class AddBasiqProfileFieldsToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :middle_name, :string
    add_column :users, :mobile_number, :string
  end
end
