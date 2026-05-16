require "test_helper"

class Provider::FactoryTest < ActiveSupport::TestCase
  test "filters provider configs for Australia demo routing" do
    configs = [
      { key: "basiq", regions: %w[au] },
      { key: "simplefin", regions: %w[us] },
      { key: "legacy" }
    ]

    filtered = Provider::Factory.filter_connection_configs_by_region(configs, "au")

    assert_equal [ "basiq" ], filtered.pluck(:key)
  end

  test "filters provider configs for United States demo routing" do
    configs = [
      { key: "basiq", regions: %w[au] },
      { key: "simplefin", regions: %w[us] },
      { key: "legacy" }
    ]

    filtered = Provider::Factory.filter_connection_configs_by_region(configs, "us")

    assert_equal [ "simplefin", "legacy" ], filtered.pluck(:key)
  end
end
