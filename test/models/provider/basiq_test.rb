require "test_helper"

class Provider::BasiqTest < ActiveSupport::TestCase
  test "server token cache key is scoped to connection settings" do
    provider = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )

    same_settings = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )

    different_key = Provider::Basiq.new(
      api_key: "key-two",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )

    different_url = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://example.basiq.test",
      version: "3.0"
    )

    assert_equal provider.send(:token_cache_key), same_settings.send(:token_cache_key)
    refute_equal provider.send(:token_cache_key), different_key.send(:token_cache_key)
    refute_equal provider.send(:token_cache_key), different_url.send(:token_cache_key)
    refute_includes provider.send(:token_cache_key), "key-one"
  end

  test "create_user posts required BASIQ profile payload" do
    provider = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )
    provider.stubs(:server_access_token).returns("server-token")

    profile = {
      email: "gavin@hooli.com",
      mobile: "+61410888666",
      firstName: "Gavin",
      middleName: "",
      lastName: "Belson"
    }

    Provider::Basiq.expects(:post).with(
      "https://au-api.basiq.io/users",
      has_entries(
        headers: has_entries(
          "Authorization" => "Bearer server-token",
          "Content-Type" => "application/json",
          "basiq-version" => "3.0"
        ),
        body: profile.to_json
      )
    ).returns(OpenStruct.new(code: 201, body: { id: "user-123" }.to_json))

    assert_equal({ id: "user-123" }, provider.create_user(profile: profile))
  end

  test "retries bearer request once after unauthorized response" do
    provider = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )
    provider.stubs(:server_access_token).returns("expired-token", "fresh-token")

    Provider::Basiq.expects(:get).twice.returns(
      OpenStruct.new(code: 401, body: { error: "expired" }.to_json),
      OpenStruct.new(code: 200, body: { id: "user-123" }.to_json)
    )

    assert_equal({ id: "user-123" }, provider.get_user("user-123"))
  end
end
