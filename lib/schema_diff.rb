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
    def empty?
      empty
    end
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

  # Produce a unified-diff-style report from the LCS-based opcodes. This is
  # not byte-perfect with GNU diff but is good enough for PR review and
  # depends only on the standard library.
  def unified_diff(a, b)
    out = +"--- a/db/schema.rb (committed)\n+++ b/db/schema.rb (from migrate)\n"
    opcodes(a.lines, b.lines).each do |tag, line|
      case tag
      when :eq  then out << " #{line}"
      when :del then out << "-#{line}"
      when :add then out << "+#{line}"
      end
    end
    out
  end

  # Extract the set of tables touched by the diff, using LCS opcodes so that
  # an inserted/removed block does not cause every subsequent line to look
  # like a difference. For each :del / :add opcode we attribute the change to
  # the most recently seen enclosing `create_table` block on the appropriate
  # side, plus any table referenced directly on the changed line.
  def affected_tables(a, b)
    cur_a = nil
    cur_b = nil
    tables = []

    opcodes(a.lines, b.lines).each do |tag, line|
      case tag
      when :eq
        cur_a = update_table_context(line, cur_a)
        cur_b = update_table_context(line, cur_b)
      when :del
        cur_a = update_table_context(line, cur_a)
        tables << cur_a if cur_a
        tables.concat(direct_table_refs(line))
      when :add
        cur_b = update_table_context(line, cur_b)
        tables << cur_b if cur_b
        tables.concat(direct_table_refs(line))
      end
    end

    tables.compact.uniq
  end

  def direct_table_refs(line)
    refs = []
    line.scan(/(?:add_column|add_index|change_column|drop_table|rename_table|remove_column|create_table)\s+["']([^"']+)["']/) do |(name)|
      refs << name
    end
    refs
  end

  # Compute a sequence of [tag, line] opcodes (tags: :eq, :del, :add) using
  # the standard Longest Common Subsequence dynamic-programming table. Schema
  # files are small (typically a few hundred lines) so the O(n*m) cost is
  # negligible and we avoid pulling in `diff-lcs`.
  def opcodes(a_lines, b_lines)
    n = a_lines.length
    m = b_lines.length
    # dp[i][j] = LCS length of a_lines[0...i] vs b_lines[0...j]
    dp = Array.new(n + 1) { Array.new(m + 1, 0) }
    (1..n).each do |i|
      ai = a_lines[i - 1]
      row = dp[i]
      prev = dp[i - 1]
      (1..m).each do |j|
        row[j] = if ai == b_lines[j - 1]
                   prev[j - 1] + 1
                 else
                   prev[j] >= row[j - 1] ? prev[j] : row[j - 1]
                 end
      end
    end

    ops = []
    i = n
    j = m
    while i.positive? || j.positive?
      if i.positive? && j.positive? && a_lines[i - 1] == b_lines[j - 1]
        ops << [:eq, a_lines[i - 1]]
        i -= 1
        j -= 1
      elsif j.positive? && (i.zero? || dp[i][j - 1] >= dp[i - 1][j])
        ops << [:add, b_lines[j - 1]]
        j -= 1
      else
        ops << [:del, a_lines[i - 1]]
        i -= 1
      end
    end
    ops.reverse!
    ops
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
