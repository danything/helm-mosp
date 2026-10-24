# syntax=docker/dockerfile:1
#
# MosP勤怠管理 (https://github.com/es-mind/MosP) のソースを取得してビルドし、
# Tomcat上で動作するイメージを作成する。
#
# MOSP_REF を指定しない場合は master ブランチの最新コミットを取得するため、
# ビルドのたびに最新コードが反映される。CI からは解決済みのコミットSHAを
# 渡すことで、再現性のあるタグ付けを行う。

ARG MOSP_REPO_URL=https://github.com/es-mind/MosP.git
ARG MOSP_REF=master
# ビルド(javac)にはJDKが必要だが、実行はJREのみで足りるため
# ベースイメージを分けて最終イメージからJDK/コンパイラ分の容量を削る。
# 実行イメージはシェルもパッケージマネージャも無い distroless の Java 17 で、
# Tomcat は TOMCAT_RUNTIME_IMAGE から配布物 ($CATALINA_HOME) だけを写して使う。
ARG TOMCAT_BUILD_IMAGE=tomcat:9.0-jdk17-temurin
ARG TOMCAT_RUNTIME_IMAGE=tomcat:9.0-jre17-temurin
ARG JAVA_RUNTIME_IMAGE=gcr.io/distroless/java17-debian13
ARG CONTEXT_PATH=ROOT

# ---------------------------------------------------------------------------
# 1. MosPソース取得
# ---------------------------------------------------------------------------
FROM alpine/git:v2.54.0 AS source
ARG MOSP_REPO_URL
ARG MOSP_REF
WORKDIR /src
RUN set -eux; \
    git init mosp; \
    cd mosp; \
    git remote add origin "${MOSP_REPO_URL}"; \
    git fetch --depth 1 origin "${MOSP_REF}"; \
    git checkout FETCH_HEAD; \
    git rev-parse HEAD > /src/mosp/COMMIT_SHA; \
    rm -rf .git

# ---------------------------------------------------------------------------
# 2. コンパイル (Tomcat同梱のservlet-api/jsp-apiを使用し、実行環境とAPIバージョンを一致させる)
# ---------------------------------------------------------------------------
FROM ${TOMCAT_BUILD_IMAGE} AS build
WORKDIR /build
COPY --from=source /src/mosp /build

# 初回ユーザ登録画面(SU3000)は、セットアップウィザードのDB作成画面を
# セッションで経由したかを確認し、経由していなければログイン画面へ飛ばす。
# DBをコンテナ側で用意する構成ではこの画面を通らないため、有効なユーザが
# まだ1人も居ない場合に限り直接開けるようにする。判定にはMosP自身が
# DB接続画面で使っている confirm() (既存のconnection.xmlで接続し、有効な
# ユーザの有無を返す) をそのまま使うので、登録が済んだ時点で自動的に
# 従来どおりログイン画面へ戻る。
RUN set -eux; \
    f=src/jp/mosp/setup/action/FirstUserAction.java; \
    sed -i 's#return mospParams.getStoredVo(DbCreateVo.class.getName()) != null;#return mospParams.getStoredVo(DbCreateVo.class.getName()) != null || jp.mosp.setup.constant.SetUpStatus.EMPTY.equals(jp.mosp.setup.bean.impl.DbSetUpManagement.getInstance(mospParams, null).confirm());#' "$f"; \
    grep -q 'SetUpStatus.EMPTY.equals' "$f"

# 登録完了画面は、ウィザードのDB作成画面のVOから作成したDB名・ロール名・
# ロールパスワードを読んで表示する。DB作成画面を通らない構成ではこのVOが
# 無くNPEになる(登録自体は完了した後なので、成功したのに画面だけ落ちる)ため、
# DB欄は空で表示する。ユーザ登録画面のVOも無い場合は、ウィザードを経ずに
# この画面だけ叩かれた場合なのでログイン画面へ送る。
RUN set -eux; \
    f=src/jp/mosp/setup/action/SetupFinishAction.java; \
    sed -i \
      -e 's#DbCreateVo createVo = (DbCreateVo)mospParams.getStoredVo(DbCreateVo.class.getName());#DbCreateVo createVo = (DbCreateVo)mospParams.getStoredVo(DbCreateVo.class.getName()); if (createVo == null) { createVo = new DbCreateVo(); createVo.setTxtDbName(""); createVo.setTxtRoleName(""); createVo.setTxtRolePw(""); }#' \
      -e 's#FirstUserVo userVo = (FirstUserVo)mospParams.getStoredVo(FirstUserVo.class.getName());#FirstUserVo userVo = (FirstUserVo)mospParams.getStoredVo(FirstUserVo.class.getName()); if (userVo == null) { mospParams.setNextCommand(jp.mosp.platform.portal.action.IndexAction.CMD_SHOW); return; }#' \
      "$f"; \
    grep -q 'createVo = new DbCreateVo();' "$f"; \
    grep -q 'IndexAction.CMD_SHOW); return;' "$f"

RUN set -eux; \
    mkdir -p WEB-INF/classes; \
    find WEB-INF/lib -name '*.jar' > /tmp/classpath.txt; \
    { \
      echo "$CATALINA_HOME/lib/servlet-api.jar"; \
      echo "$CATALINA_HOME/lib/jsp-api.jar"; \
      echo "$CATALINA_HOME/lib/el-api.jar"; \
      echo "$CATALINA_HOME/lib/annotations-api.jar"; \
    } >> /tmp/classpath.txt; \
    CP="$(paste -sd: /tmp/classpath.txt)"; \
    find src -name '*.java' > /tmp/sources.txt; \
    javac -encoding UTF-8 -nowarn -d WEB-INF/classes -cp "$CP" @/tmp/sources.txt; \
    rm -rf src /tmp/classpath.txt /tmp/sources.txt

# 実行イメージの入口 (launcher/MospLauncher.java)。実行イメージにはシェルが無いので、
# 以前 docker-entrypoint.sh でしていたDB接続設定の反映をこれが行い、同じJVMで Tomcat を起こす。
COPY launcher/MospLauncher.java /launcher/src/MospLauncher.java
RUN set -eux; \
    mkdir -p /launcher/classes; \
    javac -encoding UTF-8 --release 17 -d /launcher/classes \
      -cp "$CATALINA_HOME/bin/bootstrap.jar" /launcher/src/MospLauncher.java; \
    jar --create --file /launcher/mosp-launcher.jar -C /launcher/classes .

# ---------------------------------------------------------------------------
# 3. Tomcat + MosP の配置。シェルのある Tomcat のイメージの上で組み立て、
#    $CATALINA_HOME をまるごと次の実行イメージへ写す。
#    実行イメージでは使わないもの (シェルスクリプト、Tomcat Native (APR) の
#    ライブラリ、webapps.dist) はここで消しておく。
# ---------------------------------------------------------------------------
FROM ${TOMCAT_RUNTIME_IMAGE} AS app
ARG CONTEXT_PATH

RUN rm -rf \
    "$CATALINA_HOME"/webapps/ROOT \
    "$CATALINA_HOME"/webapps/docs \
    "$CATALINA_HOME"/webapps/examples \
    "$CATALINA_HOME"/webapps/host-manager \
    "$CATALINA_HOME"/webapps/manager \
    "$CATALINA_HOME"/webapps.dist \
    "$CATALINA_HOME"/native-jni-lib \
    "$CATALINA_HOME"/bin/*.sh \
    "$CATALINA_HOME"/bin/*.tar.gz

COPY --from=build /build "$CATALINA_HOME"/webapps/${CONTEXT_PATH}

# MosPの起動ページ(404のerror-pageも兼ねる)は、URLの1つ目のセグメントを
# コンテキストパスとみなして送信先を "/<ctx>/srv/" と組み立てる。
# ROOTに配置するとこのセグメントが空になり "//srv/" ——
# ブラウザにプロトコル相対URL(= https://srv/)と解釈されるパス —— が
# 生成されてしまうため、ROOTのときだけコンテキストパス無しに書き換える。
# argを拾う位置も1つ手前にずれるので合わせて調整する。
# 書き換えが当たらなかった場合(MosP側の実装変更)はビルドを失敗させる。
RUN set -eux; \
    if [ "${CONTEXT_PATH}" = "ROOT" ]; then \
      index="$CATALINA_HOME/webapps/ROOT/pub/common/html/index.html"; \
      sed -i \
        -e 's#form.action = "/" + pathArray\[1\] + "/srv/";#form.action = "/srv/";#' \
        -e 's#if (pathArray.length > 3) {#if (pathArray.length > 2) {#' \
        -e 's#document.getElementById("arg").value = pathArray\[3\]#document.getElementById("arg").value = pathArray[2]#' \
        "$index"; \
      grep -q 'form.action = "/srv/";' "$index"; \
      grep -q 'pathArray.length > 2' "$index"; \
      grep -q 'value = pathArray\[2\]' "$index"; \
    fi

# トップページの遷移先をログイン画面(PF0010)から初回ユーザ登録画面(SU3000)に
# する。DBが用意済みで有効なユーザが居なければ登録画面、居ればMosP自身が
# ログイン画面へ転送するので、初回だけ登録画面が出て以後はログイン画面になる。
# DBを用意していない場合(素のdocker run等)はログイン画面に転送されるだけなので、
# 従来どおりのセットアップウィザード(pub/common/html/setup.html)を使うこと。
RUN set -eux; \
    index="$CATALINA_HOME/webapps/${CONTEXT_PATH}/pub/common/html/index.html"; \
    sed -i 's#name = "cmd" value="PF0010"#name = "cmd" value="SU3000"#' "$index"; \
    grep -q 'value="SU3000"' "$index"

COPY --from=build /launcher/mosp-launcher.jar "$CATALINA_HOME"/bin/mosp-launcher.jar

# ---------------------------------------------------------------------------
# 4. 実行イメージ (distroless。シェルもパッケージマネージャも無い)
#
# catalina.sh run が組み立てていた java のコマンドライン (JDK_JAVA_OPTIONS の
# --add-opens も含む) をそのまま exec の形で書き、メインクラスだけ MospLauncher
# (DB接続設定を環境変数から反映してから、同じJVMで Bootstrap start) にしている。
# ユーザは今までどおり root (公式の Tomcat のイメージと同じ。起動時に WEB-INF/xml を
# 書き換え、ログの PVC に書くため)。
# Tomcat Native (APR) は写していない。HTTP の Connector は今までも NIO で、APR は
# OpenSSL の初期化にしか使っていなかった (TLS は Ingress 側で終端する)。
# 文字コードは LANG=C.UTF-8 (distroless の既定) で、file.encoding / sun.jnu.encoding は
# 今までどおり UTF-8 になる。
# ---------------------------------------------------------------------------
FROM ${JAVA_RUNTIME_IMAGE} AS runtime
ARG CONTEXT_PATH
ARG MOSP_REF
ENV CONTEXT_PATH=${CONTEXT_PATH} \
    CATALINA_HOME=/usr/local/tomcat \
    LANG=C.UTF-8

# MosP勤怠管理 (GNU AGPLv3) を同梱しているため、イメージのメタデータにも明記する。
# AGPLv3はネットワーク越しの利用者にもソース入手手段を提供することを求めるため、
# 参照元リポジトリと本イメージがビルドされたコミットを追跡できるようにする。
LABEL org.opencontainers.image.title="MosP勤怠管理" \
      org.opencontainers.image.description="MosP勤怠管理 (es-mind/MosP) をTomcat上で動作させるコンテナイメージ" \
      org.opencontainers.image.source="https://github.com/es-mind/MosP" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision="${MOSP_REF}"

COPY --from=app /usr/local/tomcat /usr/local/tomcat
WORKDIR /usr/local/tomcat

EXPOSE 8080
# シェルが無いので、k8s の probe や initContainer で sh / curl は使えない。
# SQL を取り出すときは `MospLauncher copy SRC DST` を使う (mosp/templates/deployment.yaml の copy-sql)
ENTRYPOINT ["/usr/bin/java", \
  "--add-opens=java.base/java.lang=ALL-UNNAMED", \
  "--add-opens=java.base/java.lang.invoke=ALL-UNNAMED", \
  "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED", \
  "--add-opens=java.base/java.io=ALL-UNNAMED", \
  "--add-opens=java.base/java.util=ALL-UNNAMED", \
  "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED", \
  "--add-opens=java.rmi/sun.rmi.transport=ALL-UNNAMED", \
  "-Djava.util.logging.config.file=/usr/local/tomcat/conf/logging.properties", \
  "-Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager", \
  "-Djdk.tls.ephemeralDHKeySize=2048", \
  "-Djava.protocol.handler.pkgs=org.apache.catalina.webresources", \
  "-Dsun.io.useCanonCaches=false", \
  "-Dorg.apache.catalina.security.SecurityListener.UMASK=0027", \
  "-Dignore.endorsed.dirs=", \
  "-Dcatalina.base=/usr/local/tomcat", \
  "-Dcatalina.home=/usr/local/tomcat", \
  "-Djava.io.tmpdir=/usr/local/tomcat/temp", \
  "-classpath", "/usr/local/tomcat/bin/mosp-launcher.jar:/usr/local/tomcat/bin/bootstrap.jar:/usr/local/tomcat/bin/tomcat-juli.jar", \
  "MospLauncher"]
CMD ["start"]
