require "test_helper"

class BasiqAccountTest < ActiveSupport::TestCase
  test "upserts documented BASIQ account payload shape" do
    basiq_item = BasiqItem.create!(
      family: families(:dylan_family),
      name: "BASIQ Connection",
      basiq_user_id: "basiq-user-account-shape-test"
    )

    basiq_account = basiq_item.basiq_accounts.build

    basiq_account.upsert_basiq_snapshot!(
      {
        id: "acc-123",
        name: "Everyday Account",
        connection: "conn-456",
        institution: "AU00000",
        currency: "AUD",
        balance: "356.50",
        availableFunds: "420.28",
        status: "available",
        class: {
          type: "transaction",
          product: "Hooli Saver"
        },
        accountNo: "600000157441965"
      }
    )

    assert_equal "conn-456", basiq_account.connection_id
    assert_equal "AU00000", basiq_account.institution_id
    assert_equal "transaction", basiq_account.account_type
    assert_equal "Hooli Saver", basiq_account.account_subtype
    assert_equal "AU00000", basiq_account.institution_metadata["id"]
    assert_equal "conn-456", basiq_account.institution_metadata["connection_id"]
  end
end
