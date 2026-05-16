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

  test "create_auth_link posts mobile to BASIQ auth link endpoint" do
    provider = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )
    provider.stubs(:server_access_token).returns("server-token")

    Provider::Basiq.expects(:post).with(
      "https://au-api.basiq.io/users/user-123/auth_link",
      has_entries(
        headers: has_entries(
          "Authorization" => "Bearer server-token",
          "Content-Type" => "application/json",
          "basiq-version" => "3.0"
        ),
        body: { mobile: "+61410888666" }.to_json
      )
    ).returns(
      OpenStruct.new(
        code: 201,
        body: {
          type: "auth_link",
          userId: "user-123",
          links: { public: "https://connect.basiq.io/link-123" }
        }.to_json
      )
    )

    response = provider.create_auth_link(user_id: "user-123", mobile: "+61410888666")

    assert_equal "https://connect.basiq.io/link-123", response.dig(:links, :public)
  end

  test "auth_link_url adds connect action and callback state" do
    provider = Provider::Basiq.new(
      api_key: "key-one",
      base_url: "https://au-api.basiq.io",
      version: "3.0"
    )

    url = provider.auth_link_url(
      auth_link: { links: { public: "https://connect.basiq.io/link-123?existing=true" } },
      state: "basiq-item-123",
      action: "connect"
    )

    uri = URI.parse(url)
    params = Rack::Utils.parse_nested_query(uri.query)

    assert_equal "https", uri.scheme
    assert_equal "connect.basiq.io", uri.host
    assert_equal "/link-123", uri.path
    assert_equal "true", params["existing"]
    assert_equal "basiq-item-123", params["state"]
    assert_equal "connect", params["action"]
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
