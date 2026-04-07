# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/schema_diff"

class SchemaDiffTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures", __dir__)

  def fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  def test_normalize_strips_version_pin
    a = fixture("schema_head.rb")
    b = fixture("schema_actual_same.rb")
    refute_equal a, b, "fixtures should differ at the raw level (version line)"
    assert_equal SchemaDiff.normalize(a), SchemaDiff.normalize(b)
  end

  def test_diff_returns_empty_when_only_version_differs
    result = SchemaDiff.diff(
      head:   fixture("schema_head.rb"),
      actual: fixture("schema_actual_same.rb")
    )
    assert result.empty?
    assert_equal "", result.text
    assert_equal [], result.tables
  end

  def test_diff_detects_added_column_and_attributes_table
    result = SchemaDiff.diff(
      head:   fixture("schema_head.rb"),
      actual: fixture("schema_actual_diff.rb")
    )
    refute result.empty?
    assert_includes result.tables, "orders"
    refute_includes result.tables, "users"
    assert_match(/\+.*status/, result.text)
  end

  def test_diff_handles_nil_input
    result = SchemaDiff.diff(head: nil, actual: fixture("schema_head.rb"))
    refute result.empty?
  end

  def test_unified_diff_has_headers
    out = SchemaDiff.unified_diff("a\n", "b\n")
    assert_match(/--- a\/db\/schema\.rb/, out)
    assert_match(/\+\+\+ b\/db\/schema\.rb/, out)
    assert_match(/-a/, out)
    assert_match(/\+b/, out)
  end
end
