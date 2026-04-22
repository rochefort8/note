# note.com 記事管理リポジトリ

このリポジトリは、note.com の記事をローカルへ取得し、Markdown 化して GitHub で管理するための作業用ディレクトリです。

## ディレクトリ構成

- `201/`: 「ソフトウェア開発201の鉄則」記事
- `PTA/`: PTA 関連記事
- `others/`: その他記事
- `biztrip/`: 手動で分類した記事
- `_images/`: Markdown 本文で参照する画像（eyecatch / 本文画像）
- `note_exports_test/`: note API から取得した生データ（json/html）

## 主要スクリプト

### 1) note の記事をダウンロード

```bash
./download_note_articles.sh <note_urlname> [output_dir]
```

例:

```bash
./download_note_articles.sh rochefort10 ./note_exports_test
```

出力先には `notes/*.json` と `notes/*.html` が生成されます。

### 2) Markdown へ変換

```bash
./convert_note_to_markdown.sh <export_dir> [output_root]
```

例:

```bash
./convert_note_to_markdown.sh ./note_exports_test/rochefort10_YYYYMMDD-HHMMSS .
```

この処理で以下を実行します。

- 記事タイトル + 本文を 1 つの `.md` に統合
- `201 / PTA / others` への振り分け
- eyecatch と本文画像を `_images/` に保存
- Markdown 内画像リンクをローカル参照へ置換

## 201 フォルダ命名ルール

`201/` の記事ファイル名は以下の形式です。

- `201_XXX.md`（`XXX` は `原理` 番号の 3 桁ゼロ埋め）

重複番号がある場合は、以下のように連番サフィックスを付けています。

- `201_040.md`, `201_040_2.md`
- `201_185.md`, `201_185_2.md`

## 補足

- `- Key: ...` 行は Markdown から削除済みです。
- タイトルの表記は、`ソフトウェア開発201の鉄則 原理X:<カテゴリ>:<タイトル>` を基準に整形しています。
