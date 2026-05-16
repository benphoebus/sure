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
end
