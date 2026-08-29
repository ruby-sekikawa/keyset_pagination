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

計測前の予測（Claude の予測 / ユーザーも自分の予測を書いてOK）:
- chunk 1回(100万行)あたりの投入時間: 2〜5 秒（generate_series + 単純INSERT、WALはmax_wal_size=4GBで緩和）
- テーブルサイズ: 約600MB（計画書の見積り通り。1行あたり~50B想定）
- `SELECT count(*)` の所要時間: 0.3〜1.0 秒（全行スキャン必要、キャッシュに乗れば速い）← Phase 5 の伏線

実測結果:
- 投入: 100万行 × 10チャンク、各 1.2〜1.6 秒（予測 2〜5秒 → 予測より速い）
- テーブルのみ 574MB / インデックス込み 789MB（予測 約600MB → ほぼ的中）
- `count(*)`: 1回目 **580ms**（コールド寄り）→ 2回目 **121ms**（キャッシュ温）。← Phase 5 の伏線。
  「2回目が速い」＝バッファキャッシュ効果を早速観測。
- last_analyze: 2026-08-22 07:36:18 UTC（入っている ✅）

status 分布（重大な発見あり）:
| status | 実測件数 | 実測% | 計画書の意図% |
|---|---|---|---|
| 1 paid | 5,999,498 | 60.0% | 60% ✅ |
| 2 shipped | 3,199,370 | 32.0% | 20% |
| 0 pending | 744,907 | 7.4% | 13% |
| 3 cancelled | 55,664 | 0.56% | 6% |
| 4 refunded | **561** | **0.0056%** | **1%** |

ズレた点と理由（★重要な学び）:
- 計画書の CASE は各 WHEN で **独立した random() を呼んでいる**ため、閾値 0.60/0.80/0.93/0.99 が
  「単一乱数に対する累積しきい値」として機能していない。
  - 意図: 1つの乱数 r に対し r<0.60→paid, 0.60〜0.80→shipped… という累積分割（→ refunded=1%）
  - 実際: 各分岐で毎回サイコロを振り直すので、後段ほど到達確率が掛け算で激減（refunded≈0.0056%）
- paid だけ 60% で一致するのは、最初の分岐だけは単一乱数と等価だから。
- SQL の CASE は WHEN ごとに式を再評価する、という基本の落とし穴の実例。

修正後（単一乱数 r を FROM 側で1回生成 → 累積しきい値で分岐）で再投入した結果、意図通りに:
| status | 件数 | % | 意図% |
|---|---|---|---|
| 0 pending | 1,298,358 | 12.98% | 13% ✅ |
| 1 paid | 5,998,790 | 59.99% | 60% ✅ |
| 2 shipped | 2,001,409 | 20.01% | 20% ✅ |
| 3 cancelled | 601,400 | 6.01% | 6% ✅ |
| 4 refunded | 100,043 | 1.00% | 1% ✅ |
→ これ以降のフェーズはこの分布を前提にする。refunded=約10万件で §5.2/§6.7 の narrative と整合。

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
