# Calendar Sync & Simple Task Manager

Google カレンダー連携型のシンプルなタスク管理＆カレンダー自動同期スクリプトです。

---

## 🌟 概要

* **カレンダー同期**: 外部カレンダー（iCal）の予定をプライベートカレンダーへ定期・自動同期（重複防止対応）。
* **スタートアップ連携**: PC起動時にバックグラウンドで予定を自動最新化。
* **タスク管理**: コマンドラインから直感的にToDoの追加・確認・完了が可能。

---

## 🛠️ セットアップ

### 1. 設定ファイルの作成
`.env.example` をコピーして `.env` を作成し、カレンダーURLやWebhook URLを設定します。

```powershell
Copy-Item .env.example .env
```

### 2. Google Apps Script（同期受け取り側）の準備
1. [Google Apps Script](https://script.google.com/) で新規プロジェクトを作成。
2. リポジトリ内の `Code.gs` の内容を貼り付けて保存。
3. **「デプロイ」>「新しいデプロイ」>「ウェブアプリ」** として公開し、発行されたURLを `.env` の `GAS_SYNC_URL` に設定。

### 3. PC起動時の自動同期設定（任意）
Windows 起動時に自動でカレンダーを同期したい場合、`sync_startup.vbs` をスタートアップフォルダに配置します。

---

## 💻 基本的な使い方

このスクリプトは、AIを使わなくてもローカルで普通に使えるように作っています。通常は以下のコマンドを使います。

```powershell
# 1. 今日の予定とタスク一覧を表示
.\task.ps1

# 2. 今日の予定だけを表示
.\task.ps1 cal

# 3. タスクを追加（タイトル / 優先度 / 見積時間）
.\task.ps1 add "資料作成" high 30

# 4. 隠しタスクを追加（now / report には表示されない）
.\task.ps1 add-hidden "個人的なメモ" low 15

# 5. タスクを完了にする
.\task.ps1 done 1

# 6. タスクを削除する
.\task.ps1 del 1

# 7. 予定をGoogle Calendarへ同期（例: 90日分 / 約3ヶ月先まで）
.\task.ps1 sync 90

# 8. タスク一覧を明示的に表示
.\task.ps1 list

# 9. Copilot CLIを起動（startでも同じ。初期コンテキストを渡して対話開始）
.\task.ps1 copilot
.\task.ps1 start

# 10. 従来のGemini向けプロンプトコピー
.\task.ps1 start gemini

# 11. Copilot CLIで日報を自動生成
.\task.ps1 copilot-report
# report copilot でも同じ動作
.\task.ps1 report copilot

# 12. 複数プロジェクトを確認してタスク化・日報生成（明示的な自動化）
.\task.ps1 copilot-auto
```

### 使い方の流れ
- まずは `task.ps1` を実行して、今日の予定と未完了タスクを確認する
- 追加したい作業は `add` で登録する
- 終わった作業は `done` で完了にする
- 予定の同期が必要なら `sync` を実行する

### AI連携について
- `start` は初期コンテキストを渡したCopilot CLIの対話を開始します
- `start gemini` は従来どおりGemini向けプロンプトをクリップボードへコピーします
- `report` は日報用のプロンプトを作成する補助コマンドです
- これらは「AI脳筋連携」をするための支援機能であり、通常のタスク管理自体には依存しません
- `copilot` は同じ初期コンテキストを GitHub Copilot CLI の対話セッションへ渡します
- `copilot-report` は日報プロンプトを Copilot CLI に渡して、そのまま日報を生成します
- `COPILOT_AUTO_APPROVE=true` にするとツール実行確認を省略できます。タスク追加などを自動化したい場合だけ設定してください
- `PROJECTS_ROOT` を設定すると、Copilotに確認対象のプロジェクトルートを伝えられます。破壊的操作は自動化しません
- `copilot-auto` は `PROJECTS_ROOT` 配下を確認し、重複を避けてタスク化します。実行には上記2つの設定が必要です

```powershell
# Copilotとの対話を開始
.\task.ps1 start

# 日報生成用プロンプトを作成（任意）
.\task.ps1 report
```

---

## 📄 ライセンス
MIT License
