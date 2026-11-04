package spike;

import software.amazon.awssdk.auth.credentials.AwsCredentials;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;
import software.amazon.awssdk.auth.credentials.DefaultCredentialsProvider;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static spike.PostSigner.q;

/**
 * Genera varios escenarios de Presigned POST (uno valido y varios que S3 debe rechazar)
 * y los escribe en un JSON que consume web/index.html.
 *
 * Uso: PresignedPostSpike <bucket> <ruta-salida.json>
 * Requiere credenciales TEMPORALES en el entorno (AWS_SESSION_TOKEN), igual que el task role.
 */
public class PresignedPostSpike {

    static final long MAX_BYTES = 1_048_576L;       // 1 MiB para poder probar el rechazo facil
    static final Duration TTL = Duration.ofMinutes(5);

    record Scenario(String name, String description, String expect, int fileBytes,
                    PostSigner.Spec spec) {}

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("Uso: PresignedPostSpike <bucket> <salida.json>");
            System.exit(2);
        }
        String bucket = args[0];
        Path out = Path.of(args[1]);

        AwsCredentials resolved = DefaultCredentialsProvider.create().resolveCredentials();
        if (!(resolved instanceof AwsSessionCredentials session)) {
            System.err.println("ERROR: las credenciales NO son temporales (falta AWS_SESSION_TOKEN).");
            System.err.println("Asume el rol spike2-uploader primero (ver instrucciones).");
            System.exit(1);
            return;
        }
        PostSigner.Creds creds = new PostSigner.Creds(
                session.accessKeyId(), session.secretAccessKey(), session.sessionToken());

        String mp4 = "video/mp4";
        List<Scenario> scenarios = List.of(
            new Scenario("valid",
                "Subida correcta: key fija, video/mp4, 100 KB, con token",
                "201", 100 * 1024,
                new PostSigner.Spec("raw/spike2-valid.mp4", "raw/spike2-valid.mp4",
                        mp4, mp4, MAX_BYTES, TTL, true)),
            new Scenario("oversize",
                "Archivo de 2 MB con limite de 1 MB",
                "rechazo", 2 * 1024 * 1024,
                new PostSigner.Spec("raw/spike2-oversize.mp4", "raw/spike2-oversize.mp4",
                        mp4, mp4, MAX_BYTES, TTL, true)),
            new Scenario("wrong-key",
                "Policy firmada para una key, formulario envia otra",
                "rechazo", 100 * 1024,
                new PostSigner.Spec("raw/spike2-allowed.mp4", "raw/spike2-hacked.mp4",
                        mp4, mp4, MAX_BYTES, TTL, true)),
            new Scenario("wrong-content-type",
                "Policy exige video/mp4, formulario envia text/plain",
                "rechazo", 100 * 1024,
                new PostSigner.Spec("raw/spike2-ct.mp4", "raw/spike2-ct.mp4",
                        mp4, "text/plain", MAX_BYTES, TTL, true)),
            new Scenario("expired",
                "Policy con expiracion 60 s en el pasado",
                "rechazo", 100 * 1024,
                new PostSigner.Spec("raw/spike2-expired.mp4", "raw/spike2-expired.mp4",
                        mp4, mp4, MAX_BYTES, Duration.ofSeconds(-60), true)),
            new Scenario("no-token",
                "Credenciales temporales pero sin x-amz-security-token",
                "rechazo", 100 * 1024,
                new PostSigner.Spec("raw/spike2-notoken.mp4", "raw/spike2-notoken.mp4",
                        mp4, mp4, MAX_BYTES, TTL, false)),
            new Scenario("outside-prefix",
                "Key fuera de raw/: la policy es valida pero el rol IAM no tiene permiso",
                "rechazo", 100 * 1024,
                new PostSigner.Spec("other/spike2-outside.mp4", "other/spike2-outside.mp4",
                        mp4, mp4, MAX_BYTES, TTL, true))
        );

        Instant now = Instant.now();
        List<String> items = new ArrayList<>();
        for (Scenario sc : scenarios) {
            PostSigner.Signed signed = PostSigner.sign(creds, bucket, sc.spec(), now);
            StringBuilder fields = new StringBuilder("{");
            boolean first = true;
            for (Map.Entry<String, String> e : signed.fields().entrySet()) {
                if (!first) fields.append(',');
                fields.append(q(e.getKey())).append(':').append(q(e.getValue()));
                first = false;
            }
            fields.append('}');
            items.add("{\"name\":" + q(sc.name())
                    + ",\"description\":" + q(sc.description())
                    + ",\"expect\":" + q(sc.expect())
                    + ",\"fileBytes\":" + sc.fileBytes()
                    + ",\"url\":" + q(signed.url())
                    + ",\"fields\":" + fields + "}");
        }
        String json = "{\"generatedAt\":" + q(now.toString())
                + ",\"scenarios\":[" + String.join(",", items) + "]}";

        Files.createDirectories(out.toAbsolutePath().getParent());
        Files.writeString(out, json, StandardCharsets.UTF_8);
        System.out.println("OK: " + scenarios.size() + " escenarios escritos en " + out
                + " (policies validas por " + TTL.toMinutes() + " min)");
    }
}
