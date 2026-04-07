#!/usr/bin/env ruby
# frozen_string_literal: true

# Entrypoint invoked by action.yml. Performs the schema-diff check and writes
# the result to GITHUB_OUTPUT / GITHUB_STEP_SUMMARY. Comment posting is handled
# by scripts/post_comments.rb so that this script stays free of any GitHub API
# calls (which keeps it easy to dry-run locally).
#
# Required env:
#   WORKING_DIRECTORY  - Rails app root
#   SCHEMA_PATH        - schema.rb path relative to WORKING_DIRECTORY
#   MIGRATIONS_PATH    - migrations dir relative to WORKING_DIRECTORY
#   BASE_REF           - base branch name
#   SETUP_COMMAND
#   SCHEMA_LOAD_COMMAND
#   MIGRATE_COMMAND
#   SCHEMA_DUMP_COMMAND
#   GITHUB_OUTPUT      - provided by Actions runner
#   GITHUB_STEP_SUMMARY

require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/schema_diff"

class Runner
  def initialize(env = ENV)
    @env = env
    @workdir = env.fetch("WORKING_DIRECTORY", ".")
    @schema_path = env.fetch("SCHEMA_PATH", "db/schema.rb")
    @migrations_path = env.fetch("MIGRATIONS_PATH", "db/migrate")
    @base_ref = env.fetch("BASE_REF")
    @setup_cmd = env.fetch("SETUP_COMMAND")
    @schema_load_cmd = env.fetch("SCHEMA_LOAD_COMMAND")
    @migrate_cmd = env.fetch("MIGRATE_COMMAND")
    @schema_dump_cmd = env.fetch("SCHEMA_DUMP_COMMAND")
  end

  def run
    Dir.chdir(@workdir) do
      head_schema = File.read(@schema_path)

      # 1. Replace schema.rb with the base ref version, then schema:load.
      base_schema = capture!("git show #{shellquote(@base_ref)}:#{shellquote(@schema_path)}")
      File.write(@schema_path, base_schema)

      sh!(@setup_cmd)
      sh!(@schema_load_cmd)

      # 2. Restore the head schema, then run pending migrations against the
      #    DB. After migrate finishes, dump the schema and compare.
      File.write(@schema_path, head_schema)
      sh!(@migrate_cmd)
      sh!(@schema_dump_cmd)

      actual_schema = File.read(@schema_path)

      # Make sure the working tree ends up with whatever was committed, even
      # if a later step in the workflow inspects it.
      File.write(@schema_path, head_schema)

      result = SchemaDiff.diff(head: head_schema, actual: actual_schema)
      suspects = result.empty? ? [] : guess_suspects(result.tables)

      emit_outputs(result, suspects)
      write_summary(result, suspects)

      exit(result.empty? ? 0 : 1)
    end
  end

  private

  def guess_suspects(tables)
    changed = capture!(
      "git diff --name-only #{shellquote("origin/#{@base_ref}")}...HEAD -- #{shellquote(@migrations_path)}"
    ).lines.map(&:strip).reject(&:empty?)
    return changed if tables.empty?

    changed.select do |path|
      next false unless File.exist?(path)
      content = File.read(path)
      tables.any? { |t| content.include?(%("#{t}")) || content.include?(%(:#{t})) }
    end
  end

  def emit_outputs(result, suspects)
    return unless (out = @env["GITHUB_OUTPUT"])
    File.open(out, "a") do |f|
      f.puts "diff_found=#{result.empty? ? 'false' : 'true'}"
      f.puts "tables=#{result.tables.join(',')}"
      # Multi-line outputs use the heredoc form documented by GitHub.
      f.puts "diff_text<<__SCHEMA_DIFF_EOF__"
      f.puts result.text
      f.puts "__SCHEMA_DIFF_EOF__"
      f.puts "suspects=#{suspects.join(',')}"
    end
  end

  def write_summary(result, suspects)
    return unless (path = @env["GITHUB_STEP_SUMMARY"])
    File.open(path, "a") do |f|
      if result.empty?
        f.puts "## ✅ schema.rb is consistent with migrations"
      else
        f.puts "## ⚠️ schema.rb diverges from migrations"
        f.puts ""
        f.puts "Affected tables: #{result.tables.join(', ')}" unless result.tables.empty?
        f.puts ""
        f.puts "```diff"
        f.puts result.text
        f.puts "```"
        unless suspects.empty?
          f.puts ""
          f.puts "Suspect migrations:"
          suspects.each { |s| f.puts "- `#{s}`" }
        end
      end
    end
  end

  def sh!(cmd)
    warn "+ #{cmd}"
    system(cmd) || raise("command failed: #{cmd}")
  end

  def capture!(cmd)
    out = `#{cmd}`
    raise "command failed: #{cmd}" unless $?.success?
    out
  end

  def shellquote(s)
    "'" + s.to_s.gsub("'", %q('\\''))+ "'"
  end
end

Runner.new.run if $PROGRAM_NAME == __FILE__
