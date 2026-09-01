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

```powershell
# 今日の予定とタスク一覧の確認
powershell -ExecutionPolicy Bypass -File task.ps1 list

# カレンダーの同期（例: 今後30日分）
powershell -ExecutionPolicy Bypass -File task.ps1 sync 30

# タスクの追加（タイトル 優先度 見積分）
powershell -ExecutionPolicy Bypass -File task.ps1 add "資料作成" high 30

# タスクの完了
powershell -ExecutionPolicy Bypass -File task.ps1 done 1
```

---

## 📄 ライセンス
MIT License
