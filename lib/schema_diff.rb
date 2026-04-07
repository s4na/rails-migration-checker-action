# frozen_string_literal: true

# SchemaDiff compares two `db/schema.rb` contents and reports the differences
# in a Rails-aware way. It is intentionally dependency-free so that the action
# can run in any Ruby environment without `bundle install`.
module SchemaDiff
  module_function

  # Normalize a schema.rb so that incidental differences (trailing whitespace,
  # the migration version pin, blank-line runs) do not produce false positives.
  def normalize(text)
    return "" if text.nil?

    text
      .gsub(/ActiveRecord::Schema(?:\[[^\]]*\])?\.define\(version:\s*[^)]+\)/,
            'ActiveRecord::Schema.define(version: <ignored>)')
      .lines
      .map { |line| line.rstrip }
      .join("\n")
      .gsub(/\n{3,}/, "\n\n")
      .strip + "\n"
  end

  # Result value object returned by `diff`.
  Result = Struct.new(:empty, :text, :tables, keyword_init: true) do
    def empty? = empty
  end

  # Compare two schema strings.
  #
  # @param head   [String] the schema.rb committed on the PR branch
  # @param actual [String] the schema.rb dumped from the DB after migrate
  # @return [Result]
  def diff(head:, actual:)
    head_n   = normalize(head)
    actual_n = normalize(actual)

    if head_n == actual_n
      return Result.new(empty: true, text: "", tables: [])
    end

    Result.new(
      empty: false,
      text: unified_diff(head_n, actual_n),
      tables: affected_tables(head_n, actual_n)
    )
  end

  # A small unified-diff-ish formatter. Not byte-perfect with GNU diff but
  # good enough for human review in PR comments and avoids any gem dependency.
  def unified_diff(a, b)
    a_lines = a.lines
    b_lines = b.lines
    out = +"--- a/db/schema.rb (committed)\n+++ b/db/schema.rb (from migrate)\n"
    max = [a_lines.length, b_lines.length].max
    (0...max).each do |i|
      al = a_lines[i]
      bl = b_lines[i]
      next if al == bl && !al.nil?

      out << "-#{al}" if al
      out << "+#{bl}" if bl
    end
    out
  end

  # Best-effort extraction of table names that appear inside differing regions.
  # We walk both schemas in lock-step. For each line that differs, we attribute
  # the diff to the most recent enclosing `create_table "xxx"` block on each
  # side, plus any table named directly on the differing line.
  def affected_tables(a, b)
    a_lines = a.lines
    b_lines = b.lines
    tables = []
    cur_a = nil
    cur_b = nil
    max = [a_lines.length, b_lines.length].max

    (0...max).each do |i|
      al = a_lines[i]
      bl = b_lines[i]
      cur_a = update_table_context(al, cur_a)
      cur_b = update_table_context(bl, cur_b)
      next if al == bl

      tables << cur_a if cur_a
      tables << cur_b if cur_b
      [al, bl].compact.each do |line|
        if (m = line.match(/(?:add_column|add_index|change_column|drop_table|rename_table|remove_column|create_table)\s+["']([^"']+)["']/))
          tables << m[1]
        end
      end
    end

    tables.compact.uniq
  end

  def update_table_context(line, current)
    return current if line.nil?
    if (m = line.match(/create_table\s+["']([^"']+)["']/))
      m[1]
    elsif line.strip == "end"
      nil
    else
      current
    end
  end
end
