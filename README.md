# rails-migration-checker

GitHub Action that catches the classic "I added a migration but forgot to update `db/schema.rb`" mistake (and the inverse: hand-edited `schema.rb` that no migration produces).

## How it works

On a pull request, the action:

1. Replaces `db/schema.rb` with the version from the base branch and runs `db:schema:load`.
2. Restores the PR branch's files and runs `db:migrate`.
3. Dumps the resulting schema and compares it with the `schema.rb` committed on the PR branch.
4. If there is a diff, it fails the job, posts a PR comment with the unified diff, and (in `review` mode) drops a line-level review comment on the migration file(s) most likely responsible.

The base branch (`main` / `master`), comment style, and PR-level gating (labels, draft, title patterns) are all configurable so the action can drop into many different repositories without forking.

## Usage

```yaml
# .github/workflows/migration-check.yml
name: migration-check

on:
  pull_request:
    paths:
      - "db/migrate/**"
      - "db/schema.rb"

jobs:
  schema-sync:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # required so the action can read base ref
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ".ruby-version"
          bundler-cache: true
      - uses: s4na/rails-migration-checker-action@v1
        with:
          working-directory: .
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Name | Default | Description |
| --- | --- | --- |
| `working-directory` | `.` | Rails app root (`.`, `app/`, `backend/`, ...). |
| `schema-path` | `db/schema.rb` | Path to schema.rb relative to `working-directory`. |
| `migrations-path` | `db/migrate` | Migrations directory. |
| `base-ref` | _(auto)_ | Branch to compare against. Defaults to PR base, then repo default. |
| `ruby-version` | _(empty)_ | If set, the action installs Ruby for you via `ruby/setup-ruby`. Leave empty to reuse the caller's setup. |
| `bundler-cache` | `true` | Forwarded to `ruby/setup-ruby` when `ruby-version` is set. |
| `setup-command` | `bin/rails db:drop db:create` | DB reset command. |
| `schema-load-command` | `bin/rails db:schema:load` | Loads base `schema.rb`. |
| `migrate-command` | `bin/rails db:migrate` | Runs migrations. |
| `schema-dump-command` | `bin/rails db:schema:dump` | Dumps the resulting schema. |
| `comment-mode` | `review` | `review` (line-level), `issue` (single PR comment), or `both`. |
| `fail-on-diff` | `true` | Fail the job when a diff is found. |
| `skip-draft` | `true` | Skip the check on draft PRs. |
| `skip-title-pattern` | _(empty)_ | Ruby regex; if PR title matches, skip. |
| `required-label` | _(empty)_ | Only run when this label is present on the PR. |
| `skip-label` | _(empty)_ | Skip when this label is present on the PR. |
| `github-token` | **required** | `GITHUB_TOKEN` with `pull-requests: write`. |

## Outputs

| Name | Description |
| --- | --- |
| `diff-found` | `'true'` when a diff was detected. |
| `affected-tables` | Comma-separated list of tables involved in the diff. |

## Permissions

The job needs:

```yaml
permissions:
  contents: read
  pull-requests: write
```

## Development

```sh
ruby test/schema_diff_test.rb
```

Design notes live in [`request.md`](./request.md) and [`spec.md`](./spec.md).

## License

MIT
