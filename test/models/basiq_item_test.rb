require "test_helper"

class BasiqItemTest < ActiveSupport::TestCase
  test "start_consent creates BASIQ auth link with normalized mobile" do
    user = users(:family_admin)
    user.update!(
      first_name: "Gavin",
      last_name: "Belson",
      mobile_number: "0410 888 666"
    )

    basiq_item = BasiqItem.create!(
      family: user.family,
      name: "BASIQ",
      basiq_user_id: "user-123"
    )
    provider = mock("basiq_provider")
    auth_link = {
      type: "auth_link",
      links: { public: "https://connect.basiq.io/link-123" }
    }

    provider.expects(:create_auth_link).with(
      user_id: "user-123",
      mobile: "+61410888666"
    ).returns(auth_link)
    provider.expects(:auth_link_url).with(
      auth_link: auth_link,
      state: basiq_item.id,
      action: "connect"
    ).returns("https://connect.basiq.io/link-123?action=connect")
    basiq_item.stubs(:basiq_provider).returns(provider)

    assert_equal "https://connect.basiq.io/link-123?action=connect",
      basiq_item.start_consent(action: "connect", state: basiq_item.id, user: user)
  end
end
