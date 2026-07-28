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
ARG TOMCAT_BUILD_IMAGE=tomcat:9.0-jdk17-temurin
ARG TOMCAT_RUNTIME_IMAGE=tomcat:9.0-jre17-temurin
ARG CONTEXT_PATH=ROOT

# ---------------------------------------------------------------------------
# 1. MosPソース取得
# ---------------------------------------------------------------------------
FROM alpine/git:2.45.2 AS source
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

# ---------------------------------------------------------------------------
# 3. 実行イメージ
# ---------------------------------------------------------------------------
FROM ${TOMCAT_RUNTIME_IMAGE} AS runtime
ARG CONTEXT_PATH
ARG MOSP_REF
ENV CONTEXT_PATH=${CONTEXT_PATH}

# MosP勤怠管理 (GNU AGPLv3) を同梱しているため、イメージのメタデータにも明記する。
# AGPLv3はネットワーク越しの利用者にもソース入手手段を提供することを求めるため、
# 参照元リポジトリと本イメージがビルドされたコミットを追跡できるようにする。
LABEL org.opencontainers.image.title="MosP勤怠管理" \
      org.opencontainers.image.description="MosP勤怠管理 (es-mind/MosP) をTomcat上で動作させるコンテナイメージ" \
      org.opencontainers.image.source="https://github.com/es-mind/MosP" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.revision="${MOSP_REF}"

RUN rm -rf \
    "$CATALINA_HOME"/webapps/ROOT \
    "$CATALINA_HOME"/webapps/docs \
    "$CATALINA_HOME"/webapps/examples \
    "$CATALINA_HOME"/webapps/host-manager \
    "$CATALINA_HOME"/webapps/manager

COPY --from=build /build "$CATALINA_HOME"/webapps/${CONTEXT_PATH}
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]
