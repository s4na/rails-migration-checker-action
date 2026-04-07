#!/usr/bin/env ruby
# frozen_string_literal: true

# Posts the schema-diff result to the pull request. Uses the `gh` CLI so we
# do not need any external Ruby gems. Reads the diff from environment vars
# populated by run_check.rb's GITHUB_OUTPUT.
#
# Required env:
#   GITHUB_TOKEN
#   GITHUB_REPOSITORY
#   PR_NUMBER
#   COMMENT_MODE        - "issue" | "review" | "both"
#   DIFF_TEXT
#   TABLES              - comma-separated
#   SUSPECTS            - comma-separated migration paths
#   BASE_REF

require "json"
require "shellwords"
require "tempfile"

class CommentPoster
  def initialize(env = ENV)
    @env = env
    @repo = env.fetch("GITHUB_REPOSITORY")
    @pr = env.fetch("PR_NUMBER")
    @mode = env.fetch("COMMENT_MODE", "review")
    @diff_text = env.fetch("DIFF_TEXT", "")
    @tables = env.fetch("TABLES", "").split(",").reject(&:empty?)
    @suspects = env.fetch("SUSPECTS", "").split(",").reject(&:empty?)
    @base_ref = env.fetch("BASE_REF", "main")
  end

  def run
    return if @diff_text.strip.empty?

    case @mode
    when "issue" then post_issue_comment
    when "review" then post_review_comments
    when "both"
      post_issue_comment
      post_review_comments
    else
      warn "unknown COMMENT_MODE=#{@mode}, falling back to issue"
      post_issue_comment
    end
  end

  private

  def issue_body
    body = +"### ⚠️ schema.rb がマイグレーションと一致していません\n\n"
    body << "base (`#{@base_ref}`) の `schema.rb` を `db:schema:load` した上で本 PR のマイグレーションを `db:migrate` した結果、\n"
    body << "コミット済み `schema.rb` と差分が出ました。マイグレーションと `schema.rb` を整合させてください。\n\n"
    body << "影響テーブル: " << @tables.map { |t| "`#{t}`" }.join(", ") << "\n\n" unless @tables.empty?
    body << "<details><summary>差分</summary>\n\n```diff\n" << @diff_text << "\n```\n</details>\n"
    unless @suspects.empty?
      body << "\n容疑マイグレーション:\n"
      @suspects.each { |s| body << "- `#{s}`\n" }
    end
    body
  end

  def post_issue_comment
    Tempfile.create("body") do |f|
      f.write(issue_body)
      f.flush
      run_gh!("pr", "comment", @pr, "--repo", @repo, "--body-file", f.path)
    end
  end

  def post_review_comments
    if @suspects.empty?
      post_issue_comment
      return
    end

    sha = `git rev-parse HEAD`.strip
    any_failed = false

    @suspects.each do |path|
      line = locate_table_line(path) || 1
      body = "schema.rb と差分があります。" \
             "影響テーブル: #{@tables.join(', ')}。" \
             "このマイグレーションが原因の可能性が高いです。"
      # `path` for the GitHub review-comments API must be repo-root-relative.
      api_path = repo_relative(path)
      payload = {
        body: body,
        commit_id: sha,
        path: api_path,
        line: line,
        side: "RIGHT"
      }.to_json

      Tempfile.create("payload") do |f|
        f.write(payload)
        f.flush
        ok = system(
          "gh", "api", "--method", "POST",
          "repos/#{@repo}/pulls/#{@pr}/comments",
          "--input", f.path
        )
        unless ok
          warn "review comment for #{path} failed"
          any_failed = true
        end
      end
    end

    # If any line-level comment failed, post a single fallback issue comment
    # so the PR author still sees the diff.
    post_issue_comment if any_failed
  end

  def repo_relative(path)
    @repo_prefix ||= `git rev-parse --show-prefix`.strip
    @repo_prefix.empty? ? path : File.join(@repo_prefix, path)
  end

  def locate_table_line(path)
    return nil unless File.exist?(path)
    File.foreach(path).with_index(1) do |line, i|
      @tables.each do |t|
        return i if line.include?(%("#{t}")) || line.include?(%(:#{t}))
      end
    end
    nil
  end

  def run_gh!(*args)
    system("gh", *args) || raise("gh #{args.join(' ')} failed")
  end
end

CommentPoster.new.run if $PROGRAM_NAME == __FILE__
