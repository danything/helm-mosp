# helm-mosp

[MosP勤怠管理](https://github.com/es-mind/MosP) の最新コードを定期的に取得してDockerイメージ化し、GitHub Container Registry (GHCR) にpushしつつ、Kubernetes上にデプロイするためのHelm chartも同じリポジトリで配布しています。

## 構成

- [`Dockerfile`](Dockerfile) — [es-mind/MosP](https://github.com/es-mind/MosP) のソースを取得し、Tomcat 9 (OpenJDK 17) 上で動作するイメージをビルドします。
- [`docker-entrypoint.sh`](docker-entrypoint.sh) — 起動時に環境変数 (`MOSP_DB_URL` / `MOSP_DB_USER` / `MOSP_DB_PASSWORD` / `MOSP_DB_DRIVER`) からDB接続設定を反映します。
- [`.github/workflows/build-and-push.yml`](.github/workflows/build-and-push.yml) — 毎月1日03:00 JSTにMosPの最新コミットを確認し、未ビルドであればイメージをビルドして `ghcr.io/<owner>/mosp` にpushします。
- [`.github/workflows/publish-chart.yml`](.github/workflows/publish-chart.yml) — `chart/**` の変更をmainにpushすると、Helm chartをpackageして `oci://ghcr.io/<owner>/charts/mosp` にpushします。
- [`chart/mosp/`](chart/mosp/) — Kubernetesへデプロイするための汎用Helm chart。ドメインやPVCサイズ等は`values.yaml`でカスタマイズする(詳細は[chart/mosp/README.md](chart/mosp/README.md))。

## イメージの使い方

```sh
docker run -d -p 8080:8080 \
  -e MOSP_DB_URL="jdbc:postgresql://<db-host>:5432/mospv4" \
  -e MOSP_DB_USER="usermosp" \
  -e MOSP_DB_PASSWORD="passmosp" \
  ghcr.io/<owner>/mosp:latest
```

## Kubernetesへのデプロイ

```sh
helm install mosp oci://ghcr.io/danything/charts/mosp --version 0.1.0 \
  --namespace mosp --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=<自分のドメイン>
```

詳しくは[chart/mosp/README.md](chart/mosp/README.md)を参照してください(k3sの`HelmChart` CRD経由でのGitOpsデプロイ例も記載しています)。

### 初回のDBセットアップ

MosPにはブラウザから使える初期セットアップウィザード(DB作成・初期管理者ユーザー作成)が組み込まれているため、`sql/*.sql` を手動で流し込む必要はありません。Podが起動したら、アプリにアクセスして初期セットアップ画面の案内に従ってください。手順の詳細は[esMindの環境構築手順](https://www.e-s-mind.com/download/)を参照してください。

## ライセンス

- 本リポジトリ（Dockerfile・GitHub Actionsワークフロー・entrypointスクリプト・Helm chart）は [GNU Affero General Public License v3.0 (AGPL-3.0-or-later)](LICENSE) の下で提供します。
- ビルドされるDockerイメージには [MosP勤怠管理](https://github.com/es-mind/MosP)（Copyright (C) esMind, LLC、同じく AGPL-3.0-or-later）のコンパイル済みコードが含まれます。MosP自体のライセンス条項は [es-mind/MosP の LICENSE](https://github.com/es-mind/MosP/blob/master/LICENSE) を参照してください。
- AGPLv3は、ネットワーク経由でプログラムを利用させる場合にも対応するソースコードの入手手段を利用者に提供することを求めます（第13条）。本イメージがビルドされたMosPのコミットSHAは、イメージ内の `COMMIT_SHA` ファイル、およびGitHub Actionsが払い出すイメージタグ（コミットSHAの先頭12桁）から追跡できます。
- 「MosP」はesMind, LLCのプロダクト名です。本リポジトリ名を`mosp`ではなく`helm-mosp`としているのも、公式プロジェクトと誤認されないようにするためです。
