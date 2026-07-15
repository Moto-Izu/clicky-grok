# Clicky → Grok (xAI OAuth) フォーク作業メモ

最終更新: 2026-07-15  
作業ディレクトリ: `/Users/motos/Documents/orca/clicky`  
リモート: https://github.com/Moto-Izu/clicky-grok  

---

## 1. 目的

[farzaa/clicky](https://github.com/farzaa/clicky) の OSS 版をベースに、

- ネイティブ AI を **Claude → Grok** に変更（途中段階）
- 最終的に **Clicky = 目と口 / Local Hermes = 脳と手（computer_use / cua-driver）**
- 認証は Hermes 側（xAI OAuth 等）。Clicky は Hermes CLI を呼ぶ
- 日本語を優先言語にする
- Mac でビルドして `/Applications` から起動できるようにする

### 現行パイプライン（Hermes 委譲）

```
音声 → Apple Speech → スクショ(JPEG) → hermes chat -q … --image … -t computer_use,vision …
                                              ↓ (cua-driver で実操作)
                                         最終テキスト
                                              ↓
                                    Clicky TTS + [POINT] 指差し
```

設定: `ClickyServiceConfig.swift`（`hermesBinary`, `hermesToolsets`, `hermesYolo` 等）  
実装: `HermesAgentClient.swift` + `CompanionManager.sendTranscriptToHermesWithScreenshot`

**前提:** `hermes` が PATH 上にあること。`hermes computer-use install` 済みだと画面操作可能。

---

## 2. リポジトリ・ブランチ

| 項目 | 内容 |
|------|------|
| 上流 | `https://github.com/farzaa/clicky.git`（origin） |
| 作業成果の置き場 | `https://github.com/Moto-Izu/clicky-grok`（fork remote） |
| 別 fork 上のブランチ | `https://github.com/Moto-Izu/clicky` の `grok-oauth` |
| ローカルブランチ | `grok-main`（履歴はクリーンな再ベース。上流に含まれていた Anthropic キーらしきものが push protection に引っかかったため） |

### 注意: 上流の秘密情報

公式 upstream の `project.pbxproj` 履歴に Anthropic API キーらしき文字列があり、GitHub push protection で弾かれた。  
そのため **orphan ブランチで 1 コミットから作り直して** `clicky-grok` に push した。

---

## 3. アーキテクチャ変更（要約）

### 変更前（オリジナル Clicky）

```
音声 → AssemblyAI → スクショ + transcript → Cloudflare Worker /chat → Anthropic Claude
                                                      ↓
                                              ElevenLabs TTS
```

### 変更後（このフォーク）

```
音声 → Apple Speech（既定）→ スクショ + transcript → api.x.ai (Grok)  ※ xAI OAuth Bearer
                                                      ↓
                                              システム TTS（Worker 未設定時）
                                              or ElevenLabs（Worker 設定時）
```

| 機能 | 実装 |
|------|------|
| チャット / ビジョン | `GrokAPI.swift` → `https://api.x.ai/v1/chat/completions` |
| 認証 | `XAIOAuth.swift` → PKCE + Keychain、`auth.x.ai` |
| TTS / STT 用 Worker | 任意。未設定でも起動可 |
| Anthropic | 不要（`worker` の `/chat` は 410） |

---

## 4. 追加・主要変更ファイル

### 新規

| ファイル | 役割 |
|----------|------|
| `leanring-buddy/GrokAPI.swift` | Grok chat/completions（vision + SSE ストリーミング） |
| `leanring-buddy/XAIOAuth.swift` | xAI OAuth（PKCE、IPv4 `127.0.0.1` コールバック、refresh、Keychain） |
| `leanring-buddy/ClickyServiceConfig.swift` | Worker URL と「設定済みか」判定 |
| `scripts/install-and-launch-clicky.sh` | 隔離解除・再署名・TCC リセット補助・起動 |
| `scripts/Launch Clicky.command` | ダブルクリック用ランチャ |
| `MEMO-GROK-FORK.md` | 本メモ |

### 変更

| ファイル | 内容 |
|----------|------|
| `CompanionManager.swift` | Claude → Grok、OAuth 連携、日本語システムプロンプト |
| `CompanionPanelView.swift` | 「Sign in with xAI」、モデル Grok 4 / Grok 3 |
| `ElevenLabsTTSClient.swift` | Worker 未設定時はシステム TTS、`ja-JP` 音声 |
| `AssemblyAIStreamingTranscriptionProvider.swift` | Worker 未設定なら `isConfigured = false` |
| `AppleSpeechTranscriptionProvider.swift` | `ja-JP` 優先 |
| `OpenAIAudioTranscriptionProvider.swift` | language `ja` |
| `OverlayWindow.swift` | 歓迎文・指差しフレーズを日本語 |
| `Info.plist` | `VoiceTranscriptionProvider` = `apple` |
| `worker/src/index.ts` | `/chat` 廃止、TTS + AssemblyAI のみ |
| `README.md` / `AGENTS.md` | Grok + OAuth 前提のドキュメント |

### 残しているレガシー

- `ClaudeAPI.swift` … 未使用（デフォルト経路では呼ばない）
- `ElementLocationDetector.swift` … Claude Computer Use 向け。指差しは主に `[POINT:…]` タグ経路

---

## 5. xAI OAuth の仕様（実装準拠）

LiteLLM / 公開共有クライアント相当:

| 項目 | 値 |
|------|-----|
| Issuer | `https://auth.x.ai` |
| Discovery | `https://auth.x.ai/.well-known/openid-configuration` |
| Client ID | `b1a00492-073a-47ea-816f-4c329264a828` |
| Scope | `openid profile email offline_access grok-cli:access api:access` |
| Redirect | `http://127.0.0.1:56121/callback`（優先ポート、空きなら別ポート） |
| Token 保存 | Keychain `service=so.clicky.xai-oauth` |
| API | `https://api.x.ai/v1` + `Authorization: Bearer <access_token>` |

### OAuth でハマった点と修正

**症状:** ブラウザで許可してもアプリ側が `empty callback`。

**原因:** Network.framework の `NWListener` が IPv6 `*:56121` で待ち、ブラウザの `http://127.0.0.1`（IPv4）や空の probe 接続で失敗。

**対策:** POSIX ソケットで **IPv4 `127.0.0.1` 固定**の HTTP コールバックサーバに差し替え。favicon 等は無視し、`code` / `error` 付きリクエストだけ完了扱い。

---

## 6. 日本語対応

- Grok システムプロンプト: **常に日本語で返答**
- 音声認識: `ja-JP` 優先
- システム TTS: `ja-JP` 優先
- オンボーディング文言・指差しバブル: 日本語

---

## 7. ビルド・起動（このマシン向け）

### 前提

- 開発者証明書が無い → **ad-hoc 署名**（`CODE_SIGN_IDENTITY="-"`）
- Bundle ID: `local.motos.clicky-grok`
- Worker なしでも動作（Apple Speech + システム TTS）

### ビルド例

```bash
cd /Users/motos/Documents/orca/clicky
DERIVED=/tmp/clicky-dd
xcodebuild \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO \
  PRODUCT_BUNDLE_IDENTIFIER="local.motos.clicky-grok" \
  ONLY_ACTIVE_ARCH=YES \
  build
```

### Applications へ入れて起動

```bash
bash /Users/motos/Documents/orca/clicky/scripts/install-and-launch-clicky.sh \
  /tmp/clicky-dd/Build/Products/Debug/Clicky.app
```

または:

```bash
xattr -cr /Applications/Clicky.app
codesign --force --deep --sign - --timestamp=none /Applications/Clicky.app
open /Applications/Clicky.app
```

- Dock には出ない（`LSUIElement`）。**メニューバー**を見る。
- Gatekeeper は ad-hoc を `spctl: rejected` することがあるが、`open` / スクリプト経由では起動可能。

### 権限（一度手動）

システム設定 → プライバシーとセキュリティ:

- マイク
- アクセシビリティ
- 画面収録
- 音声認識

---

## 8. Worker を後から使う場合

1. `worker/` で secrets:

   ```bash
   npx wrangler secret put ASSEMBLYAI_API_KEY
   npx wrangler secret put ELEVENLABS_API_KEY
   npx wrangler deploy
   ```

2. `leanring-buddy/ClickyServiceConfig.swift` の `workerBaseURL` を実際の URL に変更  
3. 必要なら `Info.plist` の `VoiceTranscriptionProvider` を `assemblyai` に戻す  

**チャット用 Anthropic キーは不要。**

---

## 9. 使い方（ユーザー操作）

1. メニューバーの Clicky を開く  
2. **Sign in with xAI**（初回のみ。成功済み）  
3. **Control + Option** で push-to-talk  
4. 画面スクショ + 発話 → Grok が日本語で返答 → TTS で読み上げ  
5. 応答末尾の `[POINT:x,y:ラベル]` でカーソルが指差し  

モデル切替: パネルの **Grok 4** / **Grok 3**

---

## 10. コミット履歴（主要）

1. Claude → Grok + xAI OAuth の骨格  
2. Worker なしでも動く設定（Apple Speech / システム TTS）  
3. install-and-launch スクリプト  
4. OAuth empty callback 修正（IPv4 POSIX サーバ）  
5. 日本語優先  

詳細は `git log` を参照。

---

## 11. 既知の制限・今後

- ad-hoc 署名のため、TCC が不安定になったり Gatekeeper 警告が出たりする。本格利用なら Xcode で Apple ID の Signing Team を設定して再ビルド推奨。
- `install-and-launch-clicky.sh` は `tccutil reset` を行うため、実行のたびに権限を求め直すことがある。
- ElevenLabs の自然な日本語ボイスは Worker + キー設定後。
- UI パネル文言の多くはまだ英語のまま（返答・音声経路は日本語優先済み）。
- 公式の最新 Clicky（heyclicky.com）は private 化済み。本作業は **OSS 時点のコードベース**が対象。

---

## 12. クイック参照パス

```
/Users/motos/Documents/orca/clicky/                 # ソース
/Applications/Clicky.app                           # インストール先
/Applications/Launch Clicky (Grok).command         # ランチャ（作成済みの場合）
/tmp/clicky-dd/Build/Products/Debug/Clicky.app     # 直近ビルド成果物
```

再起動だけ:

```bash
open /Applications/Clicky.app
```

フル再セットアップ:

```bash
bash /Users/motos/Documents/orca/clicky/scripts/install-and-launch-clicky.sh
```
