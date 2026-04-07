# 仕様

## 概要
`rails-migration-checker-action` は GitHub Actions の **composite action** として配布する。Pull Request 上で動作させ、ベースブランチの `schema.rb` から再現したスキーマに PR ブランチのマイグレーションを適用した結果が、PR ブランチの `schema.rb` と一致するかを検証する。

## トリガー
利用者側で `pull_request` イベントの `paths` を `db/migrate/**` や `db/schema.rb` に絞ることを推奨する。Action 自体はイベント種別を問わず動く。

## 入力 (`inputs`)
| 名前 | 必須 | デフォルト | 説明 |
| --- | --- | --- | --- |
| `working-directory` | no | `.` | Rails アプリのルート。 |
| `schema-path` | no | `db/schema.rb` | スキーマファイルのパス (`working-directory` 相対)。 |
| `migrations-path` | no | `db/migrate` | マイグレーションディレクトリ。 |
| `base-ref` | no | `${{ github.base_ref }}` | 比較元ブランチ。空ならリポジトリのデフォルトブランチ。 |
| `setup-command` | no | `bin/rails db:drop db:create` | DB 初期化コマンド。 |
| `schema-load-command` | no | `bin/rails db:schema:load` | ベース schema.rb を流し込むコマンド。 |
| `migrate-command` | no | `bin/rails db:migrate` | マイグレーション実行コマンド。 |
| `schema-dump-command` | no | `bin/rails db:schema:dump` | 適用後の schema を再ダンプするコマンド。 |
| `github-token` | yes | — | PR コメント投稿に使う `GITHUB_TOKEN`。 |
| `comment-mode` | no | `review` | `review` (行単位レビュー) / `issue` (PR 本文コメント) / `both`。 |

Ruby/Rails 環境のセットアップ (ruby/setup-ruby、bundle install、サービスコンテナとしての DB 起動) は **呼び出し側の責務**とする。Action は Rails コマンドが実行できる前提で動く。

## 振る舞い (実行フロー)
1. **PR ブランチの schema を退避**: `${schema-path}` を一時ファイル `.tmp/schema.head.rb` にコピー。
2. **ベース ref の schema を取得**: `git show ${base_ref}:${schema-path}` の出力で `${schema-path}` を上書き。base_ref が無い場合はエラーで終了。
3. **DB 初期化**: `setup-command` を実行。
4. **schema:load**: `schema-load-command` を実行。
5. **schema を PR ブランチのものへ戻す**: 退避していた `schema.head.rb` を書き戻す。
6. **migrate**: `migrate-command` を実行。マイグレーションが追加されていればここで反映される。
7. **再ダンプ**: `schema-dump-command` を実行 → DB 実態を反映した `schema.rb` (= "actual") が生成される。
8. **比較**: 退避済みの "head schema" と "actual schema" を `lib/schema_diff.rb` で比較。
   - 完全一致 → 成功で終了。
   - 不一致 → 差分テキスト + 影響テーブル一覧を生成。
9. **原因マイグレーションの推定**: PR の差分で追加/変更されたマイグレーションファイルを `git diff --name-only origin/${base_ref}...HEAD -- ${migrations-path}` で取得し、影響テーブル名でファイル内 grep してマッチしたものを「容疑者」とする。
10. **コメント投稿**:
    - `issue` モード: PR に 1 つの本文コメント (差分全体 + 容疑ファイルリスト) を投稿。
    - `review` モード: 容疑ファイルそれぞれに対し PR レビューコメント。テーブル名がマイグレーション内のどの行にあるか正規表現で特定でき、その行が当該 PR の diff 範囲内なら **行コメント**として投稿。範囲外/特定不能なら**ファイル先頭行**にコメント。容疑ファイルが 1 つも見つからなければ最終手段として `issue` モードと同じ本文コメントを投稿。
    - `both`: 両方。
11. **終了コード**: 差分があれば `exit 1`。

## 差分検出ロジック (`lib/schema_diff.rb`)
- 入力: 2 つの `schema.rb` 文字列 (head, actual)。
- 正規化: 末尾改行・連続空行・行末空白を整える。`ActiveRecord::Schema.define(version: …)` の `version:` の値は無視する (適用済みマイグレーションのバージョンは新しい方になり、差分判定には邪魔)。
- `Diff::LCS` などの外部 gem は使わず Ruby 標準の `Tempfile` + `diff -u` シェルアウト、または独自の行ベース比較で `unified diff` 風の文字列を返す。今回は **依存追加を避けるため独自実装**で十分な簡易版で行う:
  - 行配列で `==` 比較し、不一致なら全行ベースの "expected vs actual" ブロックを返す。
  - 影響テーブル抽出: 差分行のうち `create_table "xxx"` `add_column "xxx"` `t.xxx` の親 `create_table` などを正規表現で拾い、テーブル名集合を返す。
- 公開 API:
  - `SchemaDiff.normalize(text) -> String`
  - `SchemaDiff.diff(head:, actual:) -> Result` (`Result#empty?`, `#text`, `#tables`)

## コメントテキスト雛形
```
### ⚠️ schema.rb がマイグレーションと一致していません

base (`${base_ref}`) の schema.rb に対し、本 PR のマイグレーションを適用した結果、コミットされた schema.rb と差分が出ました。

影響テーブル: `users`, `orders`

<details><summary>差分</summary>

```diff
... unified diff ...
```
</details>

容疑マイグレーション:
- db/migrate/20260407123000_add_status_to_orders.rb
```

## ファイル構成
```
action.yml                        # composite action 定義
lib/schema_diff.rb                # 差分ロジック (純粋関数; テスト対象)
scripts/run_check.rb              # action.yml から呼ばれるエントリポイント
scripts/post_comments.rb          # GitHub API へのコメント投稿
test/schema_diff_test.rb          # minitest
test/fixtures/schema_head.rb
test/fixtures/schema_actual_same.rb
test/fixtures/schema_actual_diff.rb
.github/workflows/test.yml        # CI: minitest を回す
request.md / spec.md / README.md
```

## テスト方針
- `lib/schema_diff.rb` を minitest で純粋ユニットテスト。
  - 同一 schema → `empty?` が true。
  - `version:` のみ違う → 一致扱い。
  - カラム追加差分 → `empty?` が false、`tables` に該当テーブル名が入る、`text` に diff が含まれる。
- shell スクリプトや GitHub API 呼び出し部分は本 PR ではユニットテスト対象外 (副作用が大きいため)。動作確認は別途、利用側 workflow で行う。
