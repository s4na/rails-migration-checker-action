# rails-migration-checker-action

「マイグレーションを追加したのに `db/schema.rb` を更新し忘れた」あるいは逆に「`schema.rb` を手で書き換えてしまったがそれを生むマイグレーションが無い」というよくあるミスを Pull Request 上で機械的に検知する GitHub Action です。

## 仕組み

PR で動かすと、このアクションは次を行います。

1. `db/schema.rb` をベースブランチ (main / master) のものに差し替え、`db:schema:load` で空 DB に流し込む。
2. PR ブランチのファイルを戻し、`db:migrate` でマイグレーションを実行する。
3. 適用後の DB を `db:schema:dump` で再ダンプし、PR ブランチにコミットされている `schema.rb` と比較する。
4. 差分があればジョブを失敗させ、PR コメントとして diff を投稿する。`review` モードでは原因と推定されるマイグレーションファイルへ行単位レビューコメントを付ける。

ベースブランチ (`main` / `master`)、コメントの出し方、PR 単位のキック制御 (ラベル、draft、タイトルパターン) はすべて入力で切り替えられるので、フォーク無しで色々なリポジトリにそのまま入れられます。

## 使い方

このアクションは GitHub Marketplace 形式で、他のリポジトリのワークフローから

```yaml
- uses: s4na/rails-migration-checker-action@v1
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
```

の 1 ステップとして呼び出して使う想定です。タグは固定リリース (`@v1`、`@v1.2.3`) または特定コミット SHA を指定してください。

### 最小構成 (sqlite3 アプリ)

```yaml
# .github/workflows/migration-check.yml （呼び出す側のリポジトリに置く）
name: migration-check

on:
  pull_request:
    paths:
      - "db/migrate/**"
      - "db/schema.rb"

permissions:
  contents: read
  pull-requests: write

jobs:
  schema-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # ベース ref を読むため必須
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ".ruby-version"
          bundler-cache: true

      # ↓ ここが本アクション
      - uses: s4na/rails-migration-checker-action@v1
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### postgres を使うアプリ

```yaml
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
    env:
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/app_test
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ".ruby-version"
          bundler-cache: true

      - uses: s4na/rails-migration-checker-action@v1
        with:
          working-directory: .
          base-ref: main
          comment-mode: review
          required-label: db-change      # このラベルが付いたときだけ走らせる例
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

### mono-repo (Rails アプリがサブディレクトリ)

```yaml
      - uses: s4na/rails-migration-checker-action@v1
        with:
          working-directory: backend       # ← Rails アプリの場所
          schema-path: db/schema.rb        # working-directory 相対
          migrations-path: db/migrate
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

> Ruby / DB のセットアップ (ruby/setup-ruby、bundle install、サービスコンテナ) は呼び出し側ワークフローの責務です。本アクションは `bin/rails db:schema:load` などが叩ける状態になっている前提で動きます。

## 入力 (inputs)

| 名前 | デフォルト | 説明 |
| --- | --- | --- |
| `working-directory` | `.` | Rails アプリのルート (`.`、`app/`、`backend/` など)。 |
| `schema-path` | `db/schema.rb` | `working-directory` 相対の schema.rb パス。 |
| `migrations-path` | `db/migrate` | マイグレーションディレクトリ。 |
| `base-ref` | _(自動)_ | 比較対象ブランチ。デフォルトは PR ベース → リポジトリのデフォルトブランチ。 |
| `ruby-version` | _(空)_ | 指定すると `ruby/setup-ruby` 経由で Ruby を入れる。空なら呼び出し側のセットアップを再利用。 |
| `bundler-cache` | `true` | `ruby-version` を指定したときに `ruby/setup-ruby` に渡す。 |
| `setup-command` | `bin/rails db:drop db:create` | DB を作り直すコマンド。 |
| `schema-load-command` | `bin/rails db:schema:load` | ベース `schema.rb` を読み込むコマンド。 |
| `migrate-command` | `bin/rails db:migrate` | マイグレーション実行コマンド。 |
| `schema-dump-command` | `bin/rails db:schema:dump` | 結果のスキーマを再ダンプするコマンド。 |
| `comment-mode` | `review` | `review` (行単位レビュー) / `issue` (PR 本文に 1 件) / `both`。 |
| `fail-on-diff` | `true` | 差分があるときジョブを失敗させる。`false` にするとコメントだけ投稿。 |
| `skip-draft` | `true` | draft PR をスキップする。 |
| `skip-title-pattern` | _(空)_ | Ruby 正規表現。PR タイトルにマッチしたらスキップ。 |
| `required-label` | _(空)_ | 指定すると、このラベルが付いている PR でだけ実行する。 |
| `skip-label` | _(空)_ | 指定すると、このラベルが付いている PR ではスキップする。 |
| `github-token` | **必須** | `pull-requests: write` 権限を持つ `GITHUB_TOKEN`。 |

## 出力 (outputs)

| 名前 | 説明 |
| --- | --- |
| `diff-found` | 差分が検出されたとき `'true'`。 |
| `affected-tables` | 差分に関わったテーブルのカンマ区切り一覧。 |

## 必要な権限

ジョブには次が必要です。

```yaml
permissions:
  contents: read
  pull-requests: write
```

## 対応バージョン

CI で次のマトリクスを回しています。

- ユニットテスト: Ruby 2.7 / 3.0 / 3.1 / 3.2 / 3.3
- 統合テスト: Rails 6.1 / 7.0 / 7.1 / 7.2 / 8.0 を Ruby 互換マトリクスに従って組み合わせ

## 開発

```sh
ruby test/schema_diff_test.rb
```

設計メモは [`request.md`](./request.md) と [`spec.md`](./spec.md) にあります。

## ライセンス

MIT
