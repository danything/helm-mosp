#!/bin/sh
# 起動時に環境変数からDB接続情報を WEB-INF/xml 配下の設定へ反映する。
# 未設定の変数はイメージ同梱のデフォルト値のまま変更しない。
set -eu

WEBAPP_DIR="$CATALINA_HOME/webapps/${CONTEXT_PATH:-ROOT}"
CONN_XML="$WEBAPP_DIR/WEB-INF/xml/connection.xml"
SETUP_XML="$WEBAPP_DIR/WEB-INF/xml/setup.xml"

# <Application key="キー">の次の行に値が書かれている形式なので、
# キーの行を見つけて次の1行だけを置き換える。
# 値はパスワードなので、sedの置換文字列やawkの-vのように内容が
# エスケープとして解釈される渡し方は避け、環境変数経由で渡す。
set_xml_value() {
  file="$1"
  MOSP_XML_KEY="$2"
  MOSP_XML_VALUE="$3"
  export MOSP_XML_KEY MOSP_XML_VALUE
  [ -n "$MOSP_XML_VALUE" ] || return 0
  [ -f "$file" ] || return 0
  awk '
    replace { print "\t\t" ENVIRON["MOSP_XML_VALUE"]; replace = 0; next }
    index($0, "key=\"" ENVIRON["MOSP_XML_KEY"] "\"") { replace = 1 }
    { print }
  ' "$file" > "$file.new"
  mv "$file.new" "$file"
}

if [ -f "$CONN_XML" ]; then
  set_xml_value "$CONN_XML" "DbDriver" "${MOSP_DB_DRIVER:-}"
  set_xml_value "$CONN_XML" "DbUrl"    "${MOSP_DB_URL:-}"
  set_xml_value "$CONN_XML" "DbUser"   "${MOSP_DB_USER:-}"
  set_xml_value "$CONN_XML" "DbPass"   "${MOSP_DB_PASSWORD:-}"
fi

# 初回セットアップウィザードはconnection.xmlではなくsetup.xmlの値でDBに接続し、
# MosP用のデータベースとロールを作る。デフォルトが localhost の postgres
# スーパユーザ固定のため、ここを実際の接続先に合わせておかないとウィザードが
# DBに接続できない (SUE001)。
if [ -f "$SETUP_XML" ]; then
  # jdbc:postgresql://host:port/dbname を分解してウィザードの初期値にする。
  case "${MOSP_DB_URL:-}" in
    jdbc:postgresql://*/*)
      mosp_authority="${MOSP_DB_URL#jdbc:postgresql://}"
      mosp_dbname="${mosp_authority#*/}"
      mosp_dbname="${mosp_dbname%%\?*}"
      mosp_authority="${mosp_authority%%/*}"
      mosp_port=""
      case "$mosp_authority" in
        *:*) mosp_port="${mosp_authority##*:}" ;;
      esac
      set_xml_value "$SETUP_XML" "DefaultServerName" "${mosp_authority%%:*}"
      set_xml_value "$SETUP_XML" "DefaultPort" "$mosp_port"
      set_xml_value "$SETUP_XML" "DefaultDbName" "$mosp_dbname"
      ;;
  esac
  # ウィザードがDB/ロールの作成に使うスーパユーザ。
  # パスワード(SuperUserPassword)はあえて埋めない。セットアップウィザードは
  # 認証なしで公開されており、DB接続画面のパスワード入力がその唯一のゲートに
  # なっている。埋めてしまうと空欄のまま誰でも次の画面まで進めてしまい、
  # そこにはMosP用ロールのパスワードが平文で表示される。
  set_xml_value "$SETUP_XML" "SuperUserName" "${MOSP_DB_SUPERUSER:-}"
  # ウィザードが作成する、MosPが以後の接続に使うロール。
  # connection.xml側と食い違うとセットアップ後にログインできなくなるため、
  # 同じ MOSP_DB_USER / MOSP_DB_PASSWORD から埋める。
  set_xml_value "$SETUP_XML" "DefaultDbUser" "${MOSP_DB_USER:-}"
  set_xml_value "$SETUP_XML" "DefaultDbPassword" "${MOSP_DB_PASSWORD:-}"
fi

exec "$@"
