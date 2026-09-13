# Keyset Pagination Lab

1000万行の `orders` テーブルに対し、フィルタ・ソート・ページネーションが効く API を **p95 < 100ms** で実装する学習用リポジトリ。
「OFFSET はなぜ遅いのか」「複合インデックスの列順をどう決めるか」を、EXPLAIN と実測で確かめながら手を動かす。

- **[SUMMARY.md](./SUMMARY.md)** — 結論・要点の早見表（まずこれ）
- **[NOTES.md](./NOTES.md)** — 予測→実測→ズレの理由まで含む詳細な実測ログ（成果物）
- **[keyset-pagination-implementation-plan.md](./keyset-pagination-implementation-plan.md)** — 元の実装計画書

---

## 構成

| 項目 | 内容 |
|---|---|
| DB | PostgreSQL 16（Docker） |
| App | Rails 8.1 / Ruby 3.4.9（ホスト実行） |
| データ | orders 1000万行（574MB）、status 分布 paid60% / shipped20% / pending13% / cancelled6% / refunded1% |

```
.
├── docker-compose.yml        # PostgreSQL 16（設定を command で明示注入）
├── SUMMARY.md / NOTES.md     # 成果物ドキュメント
└── keyset_lab/               # Rails アプリ
    ├── app/models/order.rb            # scope(page_order/seek_after), approximate_count
    ├── app/models/order_stat.rb       # カウンタテーブル（COUNT回避策の1つ）
    ├── app/queries/cursor.rb          # カーソル符号化（iso8601(6)+Base64）
    ├── app/queries/order_page_query.rb# 1ページ取得（LIMIT+1でhas_next判定）
    ├── app/controllers/api/orders_controller.rb
    ├── lib/tasks/seed_orders.rake     # 1000万行投入
    ├── lib/tasks/bench.rake           # OFFSET vs Keyset の p50/p95/p99 比較
    └── test/queries/order_page_query_test.rb
```

---

## セットアップ

前提: Docker / Ruby 3.4.x / Bundler。

```bash
# 1) PostgreSQL を起動（shared_buffers=1GB, work_mem=16MB, track_io_timing=on を注入）
docker compose up -d

# 2) 拡張を作成
docker compose exec db psql -U keyset -d keyset_lab_development \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements; CREATE EXTENSION IF NOT EXISTS pg_prewarm;"

# 3) Rails 側の依存とスキーマ
cd keyset_lab
bundle install
bin/rails db:prepare        # DB作成 + マイグレーション

# 4) 1000万行を投入（各チャンク約1.3秒 × 10、最後に ANALYZE）
bin/rails lab:seed_orders

# 5) 正解インデックスを作成（idx_c。※現状マイグレーション未化。下記「注意」参照）
docker compose exec db psql -U keyset -d keyset_lab_development \
  -c "CREATE INDEX IF NOT EXISTS idx_c ON orders (status, created_at DESC, id DESC); ANALYZE orders;"
```

DB 接続情報（`keyset_lab/config/database.yml` は環境変数で上書き可）:

| 項目 | 値 |
|---|---|
| host / port | localhost / **5433** |
| user / password | keyset / keyset |
| database | keyset_lab_development |

psql に入る:

```bash
docker compose exec db psql -U keyset -d keyset_lab_development
```

---

## 使い方

### API

```bash
cd keyset_lab && bin/rails server -p 3009
```

```bash
# 1ページ目
curl "http://localhost:3009/api/orders?status=paid"
# => {"data":[...20件...],"next_cursor":"eyJ0Ijoi..."}

# 続き（next_cursor を渡す）
curl "http://localhost:3009/api/orders?status=paid&cursor=<next_cursor>"
```

### ベンチマーク（OFFSET vs Keyset の p50/p95/p99）

```bash
cd keyset_lab && bin/rails lab:bench
# OFFSET   p50= 40ms  p95= 77ms  p99=100ms  max= ...
# Keyset   p50=  1ms  p95=  6ms  p99= 10ms  max= 16ms
```

### テスト（重複・欠落・カーソル精度の検証）

```bash
cd keyset_lab && bin/rails test test/queries/order_page_query_test.rb
```

---

## 主要な学び（詳細は SUMMARY / NOTES）

- **正しい列順 `(status, created_at, id)`** で `Sort` が消え 314ms → 0.015ms。等値→ソート→一意タイブレークの順。
- **行値比較 `(created_at, id) < (?, ?)`** は `Index Cond` に落ちる。OR手書きは `Filter` になり約3700倍遅い。
- **カーソル時刻は `iso8601(6)`（マイクロ秒）が必須**。秒に丸めると同一秒境界で取りこぼす。
- **p95 で判断する**。OFFSET は深いページで毎回遅く（p95≈77ms）、keyset は何ページ目でも数ms。
- **COUNT の壁**。正確な総件数は重い（~200ms）。総件数を出さない/近似/カウンタテーブルで回避。

---

## EXPLAIN を3秒で診断するチェックリスト

1. `Seq Scan` が出てないか（大テーブルなら赤信号）
2. `Sort` が出てないか（index で消せる並べ替えコスト）
3. `Filter` + `Rows Removed by Filter` の数字（大きい＝読んで捨てる無駄＝列順を疑う）
4. `Index Cond` になっているか（index に直行できている印）
5. `Buffers: hit/read`（20件返すのに数千〜数万なら異常）

---

## 注意

- `idx_c` は現状 **生SQLで作成**しており **Rails マイグレーション未化**（テストDBには無い。正しさ検証はindex非依存なので影響なし）。本番運用では `add_index ..., algorithm: :concurrently` でマイグレーション化するのが望ましい。
- 停止: `docker compose stop` / 破棄（データも消える）: `docker compose down -v`
- Ruby は Rails 8.1 の構文要件に合わせ 3.4.9 を使用（`keyset_lab/.ruby-version`）。
