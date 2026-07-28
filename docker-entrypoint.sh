#!/bin/sh
# 起動時に環境変数からDB接続情報を WEB-INF/xml/connection.xml へ反映する。
# 未設定の変数はイメージ同梱のデフォルト値のまま変更しない。
set -eu

WEBAPP_DIR="$CATALINA_HOME/webapps/${CONTEXT_PATH:-ROOT}"
CONN_XML="$WEBAPP_DIR/WEB-INF/xml/connection.xml"

set_conn_value() {
  key="$1"
  value="$2"
  [ -n "$value" ] || return 0
  sed -i "/key=\"${key}\"/{n;s#.*#\t\t${value}#}" "$CONN_XML"
}

if [ -f "$CONN_XML" ]; then
  set_conn_value "DbDriver" "${MOSP_DB_DRIVER:-}"
  set_conn_value "DbUrl"    "${MOSP_DB_URL:-}"
  set_conn_value "DbUser"   "${MOSP_DB_USER:-}"
  set_conn_value "DbPass"   "${MOSP_DB_PASSWORD:-}"
fi

exec "$@"
