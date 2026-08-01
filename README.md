# helm-mosp

[MosP勤怠管理](https://github.com/es-mind/MosP) の最新コードを定期的に取得してDockerイメージ化し、GitHub Container Registry (GHCR) にpushしつつ、Kubernetes上にデプロイするためのHelm chartも同じリポジトリで配布しています。

## 構成

- [`Dockerfile`](Dockerfile) — [es-mind/MosP](https://github.com/es-mind/MosP) のソースを取得し、Tomcat 9 (OpenJDK 17) 上で動作するイメージをビルドします。
- [`docker-entrypoint.sh`](docker-entrypoint.sh) — 起動時に環境変数 (`MOSP_DB_URL` / `MOSP_DB_USER` / `MOSP_DB_PASSWORD` / `MOSP_DB_DRIVER`) からDB接続設定を、`MOSP_DB_SUPERUSER` / `MOSP_DB_SUPERUSER_PASSWORD` と合わせて初期セットアップウィザードの接続先設定を反映します。
- [`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml) — 毎月1日03:00 JSTにMosPの最新コミットを確認し、未ビルドであればイメージをビルドして `ghcr.io/<owner>/mosp` にpushします(`Dockerfile`等を変更したときは同じコミットでも作り直します)。
- [`.github/workflows/publish-chart.yml`](.github/workflows/publish-chart.yml) — `mosp/**` の変更をmainにpushすると、Helm chartをpackageして `oci://ghcr.io/<owner>/charts/mosp` にpushします。
- [`mosp/`](mosp/) — Kubernetesへデプロイするための汎用Helm chart。ディレクトリ名はchart名と一致させる必要があるため `mosp` としています。

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
helm install mosp oci://ghcr.io/danything/charts/mosp --version 0.2.1 \
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
| `postgresql.superuser` | `mosp` | DBコンテナを初期化するスーパユーザ。初期セットアップウィザードがDB・ロールの作成に使う |
| `postgresql.user` | `usermosp` | 初期セットアップウィザードが作成し、以後MosPがDB接続に使うロール。`postgresql.superuser` とは別名にすること |
| `postgresql.database` | `mospv4` | MosPが使うDB名。初期セットアップウィザードが作成するため、DBコンテナ側では作らない |
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
  version: 0.2.1
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

### 初回のDBセットアップ

MosPにはブラウザから使える初期セットアップウィザード(DB作成・初期管理者ユーザー作成)が組み込まれているため、`sql/*.sql` を手動で流し込む必要はありません。トップページはログイン画面なので、Podが起動したら **`https://<ホスト名>/pub/common/html/setup.html`** を開いてウィザードを実行してください。管理者のIDとパスワードは決め打ちではなく、ウィザードの「最初のユーザー」画面で自分で設定します。手順の詳細は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

ウィザードはDB接続画面で「サーバ/ポート番号/Postgresパスワード」を訊いてきます。サーバ名・ポート・DB名・作成するロール名はこのchartの設定から自動で埋まるので、入力するのは `postgresql.existingSecretKey` (既定では `db-password`) のパスワードだけです。

```sh
kubectl -n mosp get secret <Secret名> -o jsonpath='{.data.db-password}' | base64 -d
```

MosPのウィザードは本来 `localhost` の `postgres` スーパユーザ固定でDBに接続する作りで、そのままではこのchartが立てたPostgreSQLに接続できません(`SUE001 接続できませんでした`)。イメージのentrypointが起動時に `WEB-INF/xml/setup.xml` へ実際の接続先を書き込むことで、この画面が通るようにしています。

## ライセンス

- 本リポジトリ（Dockerfile・GitHub Actionsワークフロー・entrypointスクリプト・Helm chart）は [GNU Affero General Public License v3.0 (AGPL-3.0-or-later)](LICENSE) の下で提供します。
- ビルドされるDockerイメージには [MosP勤怠管理](https://github.com/es-mind/MosP)（Copyright (C) esMind, LLC、同じく AGPL-3.0-or-later）のコンパイル済みコードが含まれます。MosP自体のライセンス条項は [es-mind/MosP の LICENSE](https://github.com/es-mind/MosP/blob/master/LICENSE) を参照してください。イメージ内のMosPに加えている変更は上記の起動ページの書き換えのみで、内容は [`Dockerfile`](Dockerfile) から確認できます。
- AGPLv3は、ネットワーク経由でプログラムを利用させる場合にも対応するソースコードの入手手段を利用者に提供することを求めます（第13条）。本イメージがビルドされたMosPのコミットSHAは、イメージ内の `COMMIT_SHA` ファイル、およびGitHub Actionsが払い出すイメージタグ（コミットSHAの先頭12桁）から追跡できます。
- 「MosP」はesMind, LLCのプロダクト名です。本リポジトリ名を`mosp`ではなく`helm-mosp`としているのも、公式プロジェクトと誤認されないようにするためです。
