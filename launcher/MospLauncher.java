// MosP勤怠管理のイメージの入口。実行イメージ (distroless) にはシェルが無いので、
// 以前 docker-entrypoint.sh (sh + awk) でしていたことを Java で行い、同じ JVM の中で
// Tomcat (org.apache.catalina.startup.Bootstrap) を起こす。
//
//   MospLauncher start          … DB接続設定を環境変数から反映してから Tomcat を起動する (既定)
//   MospLauncher copy SRC DST   … SRC の中身を DST へ写して終わる (Helm chart の initContainer
//                                  copy-sql が、以前の `sh -c 'cp -a …'` の代わりに使う)
//
// 起動時の処理は docker-entrypoint.sh と同じ:
// - 未設定(空)の変数はイメージ同梱のデフォルト値のまま変更しない
// - <Application key="キー"> の次の1行を値で置き換える (値はパスワードなので、正規表現の
//   置換文字列のように内容がエスケープとして解釈される渡し方はしない)
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileVisitResult;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class MospLauncher {
    private MospLauncher() {}

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("copy")) {
            if (args.length != 3) {
                System.err.println("usage: MospLauncher copy SRC DST");
                System.exit(2);
            }
            copyTree(Path.of(args[1]), Path.of(args[2]));
            return;
        }
        configure();
        // 引数はそのまま Bootstrap へ (既定は start = catalina.sh run と同じくフォアグラウンドで待つ)
        org.apache.catalina.startup.Bootstrap.main(args.length == 0 ? new String[] {"start"} : args);
    }

    private static String env(String name) {
        String v = System.getenv(name);
        return v == null ? "" : v;
    }

    static void configure() throws IOException {
        String home = env("CATALINA_HOME");
        if (home.isEmpty()) home = "/usr/local/tomcat";
        String ctx = env("CONTEXT_PATH");
        if (ctx.isEmpty()) ctx = "ROOT";
        Path webapp = Path.of(home, "webapps", ctx);
        Path conn = webapp.resolve("WEB-INF/xml/connection.xml");
        Path setup = webapp.resolve("WEB-INF/xml/setup.xml");

        if (Files.isRegularFile(conn)) {
            setXmlValue(conn, "DbDriver", env("MOSP_DB_DRIVER"));
            setXmlValue(conn, "DbUrl", env("MOSP_DB_URL"));
            setXmlValue(conn, "DbUser", env("MOSP_DB_USER"));
            setXmlValue(conn, "DbPass", env("MOSP_DB_PASSWORD"));
        }

        // 初回セットアップウィザードはconnection.xmlではなくsetup.xmlの値でDBに接続し、
        // MosP用のデータベースとロールを作る。デフォルトが localhost の postgres
        // スーパユーザ固定のため、ここを実際の接続先に合わせておかないとウィザードが
        // DBに接続できない (SUE001)。
        if (Files.isRegularFile(setup)) {
            // jdbc:postgresql://host:port/dbname を分解してウィザードの初期値にする。
            String url = env("MOSP_DB_URL");
            String prefix = "jdbc:postgresql://";
            if (url.startsWith(prefix) && url.indexOf('/', prefix.length()) >= 0) {
                String rest = url.substring(prefix.length());
                int slash = rest.indexOf('/');
                String authority = rest.substring(0, slash);
                String dbname = rest.substring(slash + 1);
                int q = dbname.indexOf('?');
                if (q >= 0) dbname = dbname.substring(0, q);
                int lastColon = authority.lastIndexOf(':');
                String port = lastColon >= 0 ? authority.substring(lastColon + 1) : "";
                int firstColon = authority.indexOf(':');
                String server = firstColon >= 0 ? authority.substring(0, firstColon) : authority;
                setXmlValue(setup, "DefaultServerName", server);
                setXmlValue(setup, "DefaultPort", port);
                setXmlValue(setup, "DefaultDbName", dbname);
            }
            // ウィザードがDB/ロールの作成に使うスーパユーザ。
            // パスワード(SuperUserPassword)はあえて埋めない。セットアップウィザードは
            // 認証なしで公開されており、DB接続画面のパスワード入力がその唯一のゲートに
            // なっている。埋めてしまうと空欄のまま誰でも次の画面まで進めてしまい、
            // そこにはMosP用ロールのパスワードが平文で表示される。
            setXmlValue(setup, "SuperUserName", env("MOSP_DB_SUPERUSER"));
            // ウィザードが作成する、MosPが以後の接続に使うロール。
            // connection.xml側と食い違うとセットアップ後にログインできなくなるため、
            // 同じ MOSP_DB_USER / MOSP_DB_PASSWORD から埋める。
            setXmlValue(setup, "DefaultDbUser", env("MOSP_DB_USER"));
            setXmlValue(setup, "DefaultDbPassword", env("MOSP_DB_PASSWORD"));
        }
    }

    /** キーを含む行の次の1行を "\t\t値" に置き換える (docker-entrypoint.sh の awk と同じ)。 */
    static void setXmlValue(Path file, String key, String value) throws IOException {
        if (value.isEmpty() || !Files.isRegularFile(file)) return;
        // 改行で区切り、最後の改行の有無も含めて元の形を保つ
        String text = new String(Files.readAllBytes(file), StandardCharsets.UTF_8);
        List<String> lines = new ArrayList<>(Arrays.asList(text.split("\n", -1)));
        boolean trailingNewline = text.endsWith("\n");
        if (trailingNewline) lines.remove(lines.size() - 1);
        String needle = "key=\"" + key + "\"";
        StringBuilder out = new StringBuilder(text.length() + value.length());
        boolean replace = false;
        for (String line : lines) {
            if (replace) {
                out.append("\t\t").append(value).append('\n');
                replace = false;
                continue;
            }
            if (line.contains(needle)) replace = true;
            out.append(line).append('\n');
        }
        Path tmp = file.resolveSibling(file.getFileName() + ".new");
        Files.write(tmp, out.toString().getBytes(StandardCharsets.UTF_8));
        Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
    }

    /** cp -a SRC/. DST/ 相当 (属性も写す)。 */
    static void copyTree(Path src, Path dst) throws IOException {
        Files.walkFileTree(src, new SimpleFileVisitor<>() {
            @Override
            public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) throws IOException {
                Path target = dst.resolve(src.relativize(dir).toString());
                if (!Files.isDirectory(target)) Files.createDirectories(target);
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                Files.copy(file, dst.resolve(src.relativize(file).toString()),
                        StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.COPY_ATTRIBUTES,
                        LinkOption.NOFOLLOW_LINKS);
                return FileVisitResult.CONTINUE;
            }
        });
    }
}
