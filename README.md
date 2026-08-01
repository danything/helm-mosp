# helm-mosp

[MosP勤怠管理](https://github.com/es-mind/MosP) の最新コードを定期的に取得してDockerイメージ化し、GitHub Container Registry (GHCR) にpushしつつ、Kubernetes上にデプロイするためのHelm chartも同じリポジトリで配布しています。

## 構成

- [`Dockerfile`](Dockerfile) — [es-mind/MosP](https://github.com/es-mind/MosP) のソースを取得し、Tomcat 9 (OpenJDK 17) 上で動作するイメージをビルドします。
- [`docker-entrypoint.sh`](docker-entrypoint.sh) — 起動時に環境変数 (`MOSP_DB_URL` / `MOSP_DB_USER` / `MOSP_DB_PASSWORD` / `MOSP_DB_DRIVER`) からDB接続設定を反映します。
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
helm install mosp oci://ghcr.io/danything/charts/mosp --version 0.1.1 \
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
| `postgresql.user` | `mosp` | DBユーザー名 |
| `postgresql.database` | `mospv4` | DB名 |
| `postgresql.existingSecret` | `""` | 空ならchartがパスワードを自動生成してSecretを作成(`helm upgrade`時も既存値を維持)。既存Secretを使う場合はここに名前を指定 |
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
  version: 0.1.1
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

MosPにはブラウザから使える初期セットアップウィザード(DB作成・初期管理者ユーザー作成)が組み込まれているため、`sql/*.sql` を手動で流し込む必要はありません。Podが起動したら、アプリにアクセスして初期セットアップ画面の案内に従ってください。手順の詳細は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

## ライセンス

- 本リポジトリ（Dockerfile・GitHub Actionsワークフロー・entrypointスクリプト・Helm chart）は [GNU Affero General Public License v3.0 (AGPL-3.0-or-later)](LICENSE) の下で提供します。
- ビルドされるDockerイメージには [MosP勤怠管理](https://github.com/es-mind/MosP)（Copyright (C) esMind, LLC、同じく AGPL-3.0-or-later）のコンパイル済みコードが含まれます。MosP自体のライセンス条項は [es-mind/MosP の LICENSE](https://github.com/es-mind/MosP/blob/master/LICENSE) を参照してください。イメージ内のMosPに加えている変更は上記の起動ページの書き換えのみで、内容は [`Dockerfile`](Dockerfile) から確認できます。
- AGPLv3は、ネットワーク経由でプログラムを利用させる場合にも対応するソースコードの入手手段を利用者に提供することを求めます（第13条）。本イメージがビルドされたMosPのコミットSHAは、イメージ内の `COMMIT_SHA` ファイル、およびGitHub Actionsが払い出すイメージタグ（コミットSHAの先頭12桁）から追跡できます。
- 「MosP」はesMind, LLCのプロダクト名です。本リポジトリ名を`mosp`ではなく`helm-mosp`としているのも、公式プロジェクトと誤認されないようにするためです。
