# Keyset Pagination Lab — 実測ノート

> このノートが成果物です（計画書 §10）。各フェーズで「予測 → 実測 → ズレと理由」を必ず埋める。
> 時間ではなく **ブロック数(Buffers)** で考える癖をつける（計画書 §4.3）。

- 環境: PostgreSQL 16 (Docker) / Rails 8.1 / Ruby 3.3 (host)
- DB接続: `localhost:5433` user=keyset db=keyset_lab_development
- psql に入る: `docker compose exec db psql -U keyset -d keyset_lab_development`

---

## 進捗

| Phase | 内容 | 状態 |
|---|---|---|
| 0 | スキーマ定義 | 着手中 |
| 1 | 1000万行投入 | 未 |
| 2 | ベースライン計測 | 未 |
| 3 | インデックス比較実験 | 未 |
| 4 | Keyset実装 | 未 |
| 5 | COUNT問題 | 未 |
| 6 | p95計測 | 未 |
| 7 | 発展 | 未 |

---

## Phase 0: スキーマ定義  ✅ 完了

やろうとしたこと:
- インデックスを一切張らずに orders テーブルを作る（Phase 2 で「インデックスなしの地獄」を体験するため）

実測結果:
- `db:migrate` 成功（CreateOrders, 0.0153s）
- `\d orders`: インデックスは `orders_pkey` (PRIMARY KEY, btree(id)) のみ。PK以外なし ✅
- カラム型: id=bigint, user_id=bigint, status=smallint(limit:2), total_cents=integer, created_at=timestamp(6) without time zone, いずれも NOT NULL

補足メモ:
- created_at は `timestamp(6) without time zone`（Rails既定）。計画書§6.5は timestamptz を想定するが、
  マイクロ秒精度(6桁)は保持されるため keyset の精度要件は満たす。TZは Rails/DB とも UTC で統一済み。
  Phase 4 の iso8601(6) 検証で改めて確認する。
- 環境: Ruby は Rails 8.1 の構文要件に合わせ 3.4.9 に変更（3.3.0 では actionview が SyntaxError）。

---

## Phase 1: 1000万行の投入

計測前の予測:
- chunk 1回(100万行)あたりの投入時間: ____ 秒
- テーブルサイズ: ____ MB
- `SELECT count(*)` の所要時間: ____ 秒  ← Phase 5 の伏線

実測結果:
-

ズレた点と理由:
-

---

## Phase 2: ベースライン計測（インデックスなし）

計測前の予測（計画書 §4.1）:
- Q1. status='paid'(600万件)で絞り created_at DESC で20件取るのに: ____ ms
- Q2. OFFSET 0 と OFFSET 100000 の速度差: ____ 倍
- Q3. 20行返すためにDBは何行読む: ____ 行

実測（§4.4 記録テンプレート）:

| OFFSET | 実行時間 | Buffers (hit/read) | actual rows | Sortの有無 |
|---|---|---|---|---|
| 0 | | | | |
| 100,000 | | | | |
| 1,000,000 | | | | |

ズレた点と理由:
-

---

## Phase 3: インデックス設計の比較実験

予測:
- どのパターンで Sort ノードが消えるか: ____
- status=4(refunded, 1%) でパターンB の Rows Removed by Filter: ____ 行

実測:

| パターン | 実行時間 | Buffers | Sortノード | Rows Removed by Filter |
|---|---|---|---|---|
| なし | | | | |
| A (created_at) | | | | |
| B (created_at, status) | | | | |
| C (status, created_at, id) | | | | |

- idx_c サイズ: ____
- DESC有無の逆順スキャン検証: ____

ズレた点と理由:
-

---

## Phase 4: Keyset Pagination の実装

- Index Cond に ROW(...) が入ったか: ____
- OR手書き版との EXPLAIN 差分: ____
- カーソルが何ページ目でも Buffers 一定か: ____
- iso8601(6) → to_s に変えるとテストが落ちるか: ____

---

## Phase 5: COUNT の壁

- `COUNT(*) WHERE status=1` 単体の実行時間: ____ ms
- 3つの選択肢（総件数を出さない / 近似 / カウンタテーブル）のトレードオフ:
  -

---

## Phase 6: p95 の計測と比較

| 方式 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| OFFSET | | | | |
| Keyset | | | | |

- 目標 p95 < 100ms 達成: ____
- StackProf アプリ層内訳: ____

---

## Phase 7: 発展課題（任意）
-
