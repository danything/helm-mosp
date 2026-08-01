# helm-mosp

[MosP勤怠管理](https://github.com/es-mind/MosP) の最新コードを定期的に取得してDockerイメージ化し、GitHub Container Registry (GHCR) にpushしつつ、Kubernetes上にデプロイするためのHelm chartも同じリポジトリで配布しています。

## 構成

- [`Dockerfile`](Dockerfile) — [es-mind/MosP](https://github.com/es-mind/MosP) のソースを取得し、Tomcat 9 (OpenJDK 17) 上で動作するイメージをビルドします。
- [`docker-entrypoint.sh`](docker-entrypoint.sh) — 起動時に環境変数 (`MOSP_DB_URL` / `MOSP_DB_USER` / `MOSP_DB_PASSWORD` / `MOSP_DB_DRIVER`) からDB接続設定を、`MOSP_DB_SUPERUSER` と合わせて初期セットアップウィザードの接続先設定を反映します。
- [`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml) — 毎月1日03:00 JSTにMosPの最新コミットを確認し、未ビルドであればイメージをビルドして `ghcr.io/<owner>/mosp` にpushします(`Dockerfile`等を変更したときは同じコミットでも作り直します)。
- [`.github/workflows/publish-chart.yml`](.github/workflows/publish-chart.yml) — `mosp/**` の変更をmainにpushすると、Helm chartをpackageして `oci://ghcr.io/<owner>/charts/mosp` にpushします。
- [`mosp/`](mosp/) — Kubernetesへデプロイするための汎用Helm chart。ディレクトリ名はchart名と一致させる必要があるため `mosp` としています。DBの初期構築(ロール・データベース・スキーマ)もinit containerで行うため、インストール後はブラウザで最初のユーザーを登録するだけで使い始められます。

## イメージの使い方

```sh
docker run -d -p 8080:8080 \
  -e MOSP_DB_URL="jdbc:postgresql://<db-host>:5432/mospv4" \
  -e MOSP_DB_USER="usermosp" \
  -e MOSP_DB_PASSWORD="passmosp" \
  ghcr.io/<owner>/mosp:latest
```

MosPのwarはコンテキストパス配下(`/mosp/` 等)に置く前提で作られていますが、本イメージは `webapps/ROOT` に配置してドメイン直下で使えるようにしています。それに伴い、起動ページ (`pub/common/html/index.html`) がURLの先頭セグメントをコンテキストパスとみなして送信先を組み立てている箇所だけ、ビルド時に書き換えています(ROOT配置ではこれが `//srv/` = プロトコル相対URLになり、ブラウザが別ホストへアクセスしてしまうため)。コンテキストパス配下に置きたい場合はビルド引数 `CONTEXT_PATH` を指定してください(その場合この書き換えは行われません)。

## Kubernetesへのデプロイ

`oci://ghcr.io/danything/charts/mosp` としてOCI公開しているので、リポジトリを追加せず直接installできます。

```sh
helm install mosp oci://ghcr.io/danything/charts/mosp --version 0.3.0 \
  --namespace mosp --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=kintai.example.com \
  --set persistence.storageClassName=<自分のStorageClass>
```

このリポジトリを直接cloneしている場合は `./mosp` をパスとして指定しても同じです。Ingressを使わない場合は `kubectl port-forward` や `NodePort`/`LoadBalancer` のServiceを別途用意してアクセスしてください。

### values

| キー | デフォルト | 説明 |
| --- | --- | --- |
| `image.repository` | `ghcr.io/danything/mosp` | MosPイメージ |
| `image.tag` | `latest` | イメージタグ |
| `image.pullPolicy` | `IfNotPresent` | `latest` を使う場合は `Always` にしないと再ビルドが反映されない |
| `timezone` | `Asia/Tokyo` | 各コンテナの `TZ` |
| `service.port` | `8080` | mosp Serviceの公開ポート |
| `postgresql.image.repository` / `.tag` | `postgres` / `13` | MosPの[推奨環境](https://www.e-s-mind.com/environment/)に合わせてPostgreSQL 13系に固定している(Renovateの更新対象からも13系以外を除外) |
| `postgresql.superuser` | `mosp` | DBコンテナを初期化するスーパユーザ。DB・ロール・スキーマの作成に使う |
| `postgresql.user` | `usermosp` | MosPがDB接続に使うロール。init containerが作成する。`postgresql.superuser` とは別名にすること |
| `postgresql.database` | `mospv4` | MosPが使うDB名。init containerが作成するため、DBコンテナ側では作らない |
| `postgresql.existingSecret` | `""` | 空ならchartがパスワードを自動生成してSecretを作成(`helm upgrade`時も既存値を維持)。既存Secretを使う場合はここに名前を指定。スーパユーザとMosP用ロールの双方に同じパスワードを使う |
| `postgresql.existingSecretKey` | `db-password` | 上記Secretのキー名 |
| `persistence.storageClassName` | `""` | 空ならクラスタのデフォルトStorageClassを使用 |
| `persistence.db.size` | `5Gi` | DB用PVCサイズ |
| `persistence.logs.enabled` | `true` | MosPのログ(`webapps/ROOT/logs`)を永続化するか |
| `persistence.logs.size` | `1Gi` | ログ用PVCサイズ |
| `resources` | `{}` | 両コンテナ共通のresources |
| `extraEnv` | `[]` | mospコンテナへの追加環境変数 |
| `ingress.enabled` | `false` | Traefik `IngressRoute` を作るか |
| `ingress.host` | `mosp.example.com` | 公開ホスト名 |
| `ingress.entryPoints` | `[websecure]` | Traefikのentrypoint |
| `ingress.certResolver` | `""` | 空ならtlsブロックを出力しない |
| `ingress.middlewares` | `[]` | 例: `[{name: forward-auth, namespace: auth}]` |

`ingress.*` はTraefikの `IngressRoute` CRD専用です。NGINX Ingress等を使う場合は [`mosp/templates/ingress.yaml`](mosp/templates/ingress.yaml) を書き換えてください。またArgoCDでの運用を想定し、PVCには `argocd.argoproj.io/sync-options: Prune=false,Delete=false` を付与しています(Application削除時にデータが消えないように)。

### k3sのHelmChart CRD経由でのデプロイ例

GitOps管理しているクラスタなら、k3s組み込みのhelm-controllerに直接デプロイさせることもできます。

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: mosp
  namespace: kube-system
spec:
  chart: oci://ghcr.io/danything/charts/mosp
  version: 0.3.0
  targetNamespace: mosp
  createNamespace: true
  values:
    ingress:
      enabled: true
      host: mosp.example.com
      certResolver: mydnschallenge
    persistence:
      storageClassName: local-path-retain
    postgresql:
      existingSecret: mosp-secrets
```

### 初回セットアップ

**インストールしたらホスト名を開くだけです。** DBの作成もスキーマの投入もchartが済ませてあるので、最初の画面はMosPの「最初のユーザー」登録になります。氏名とユーザーIDを入れて登録すると、以後そのURLは通常のログイン画面に変わります(この出し分けはMosP自身の判定を使っているので、切り替えは自動です)。

登録直後のパスワードはMosPの仕様で**ユーザーIDと同じ値**です(初期パスワードはユーザーIDから生成されます)。最初のログイン時にパスワード変更を求められるので、そこで自分のパスワードを設定してください。手順の詳細は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

> **注意**: デプロイしてから最初のユーザーを登録するまでの間は、そのURLを開いた誰でも管理者を作れます。公開する場所にインストールする場合は、デプロイ直後に登録を済ませてください。登録が済めば登録画面は閉じ、ログイン画面になります。

内部的には次のことをしています。

- **DBの用意** — mosp Podのinit containerが、MosPの初期セットアップウィザードのDB作成画面と同じ手順(ロール作成 → `CREATE DATABASE ... ENCODING 'UTF8' TEMPLATE template0` → イメージ同梱の `sql/*.sql` をスーパユーザで実行 → `grant*.sql` は権限付与先を `postgresql.user` に置換して実行)を実行します。DBが既にあれば何もしません。
- **登録画面の解放** — MosPの初回ユーザ登録画面は、ウィザードのDB作成画面をセッションで経由したかを確認し、経由していなければログイン画面へ飛ばします。DBをchartが用意する構成ではその画面を通らないため、**有効なユーザがまだ1人も居ない場合に限り**直接開けるよう `FirstUserAction` にビルド時パッチを当てています(判定にはMosP自身が使っている `confirm()` をそのまま利用)。
- **トップページの遷移先** — `pub/common/html/index.html` の遷移先をログイン画面(`PF0010`)から初回ユーザ登録画面(`SU3000`)に書き換えています。

素の `docker run` などDBを自分で用意する場合は、この登録画面は開かず(接続先にユーザが居るか判定できないため)ログイン画面になります。その場合はMosP本来のセットアップウィザード `https://<ホスト名>/pub/common/html/setup.html` を使ってください。ウィザードのサーバ名・ポート・DB名・ロール名は環境変数から自動で埋まりますが、「Postgresパスワード」だけは自動で埋めていません。**このウィザードは認証なしで公開されており、この入力欄が唯一のゲート**だからです。

## ライセンス

- 本リポジトリ（Dockerfile・GitHub Actionsワークフロー・entrypointスクリプト・Helm chart）は [GNU Affero General Public License v3.0 (AGPL-3.0-or-later)](LICENSE) の下で提供します。
- ビルドされるDockerイメージには [MosP勤怠管理](https://github.com/es-mind/MosP)（Copyright (C) esMind, LLC、同じく AGPL-3.0-or-later）のコンパイル済みコードが含まれます。MosP自体のライセンス条項は [es-mind/MosP の LICENSE](https://github.com/es-mind/MosP/blob/master/LICENSE) を参照してください。イメージ内のMosPに加えている変更は上記の起動ページの書き換えのみで、内容は [`Dockerfile`](Dockerfile) から確認できます。
- AGPLv3は、ネットワーク経由でプログラムを利用させる場合にも対応するソースコードの入手手段を利用者に提供することを求めます（第13条）。本イメージがビルドされたMosPのコミットSHAは、イメージ内の `COMMIT_SHA` ファイル、およびGitHub Actionsが払い出すイメージタグ（コミットSHAの先頭12桁）から追跡できます。
- 「MosP」はesMind, LLCのプロダクト名です。本リポジトリ名を`mosp`ではなく`helm-mosp`としているのも、公式プロジェクトと誤認されないようにするためです。
