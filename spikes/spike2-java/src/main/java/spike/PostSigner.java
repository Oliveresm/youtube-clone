package spike;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Firma manual de un S3 Presigned POST con SigV4 (sin helpers del SDK).
 * Sin dependencias de AWS: solo javax.crypto.
 */
public final class PostSigner {

    public static final String REGION = "us-east-1";

    private static final DateTimeFormatter DATE =
            DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneOffset.UTC);
    private static final DateTimeFormatter AMZ_DATE =
            DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'").withZone(ZoneOffset.UTC);
    private static final DateTimeFormatter EXPIRATION =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    /** Credenciales temporales (las del task role en produccion). */
    public record Creds(String accessKey, String secretKey, String token) {}

    /** Lo que la policy exige (policy*) y lo que el formulario realmente envia (form*). */
    public record Spec(String policyKey, String formKey,
                       String policyContentType, String formContentType,
                       long maxBytes, Duration expiresIn, boolean includeToken) {}

    public record Signed(String url, Map<String, String> fields, String policyJson) {}

    private PostSigner() {}

    public static Signed sign(Creds c, String bucket, Spec s, Instant now) {
        String date = DATE.format(now);
        String amzDate = AMZ_DATE.format(now);
        String credential = c.accessKey() + "/" + date + "/" + REGION + "/s3/aws4_request";
        String expiration = EXPIRATION.format(now.plus(s.expiresIn()));

        List<String> conditions = new ArrayList<>();
        conditions.add("{\"bucket\":" + q(bucket) + "}");
        conditions.add("{\"key\":" + q(s.policyKey()) + "}");                       // key fija, sin starts-with
        conditions.add("{\"Content-Type\":" + q(s.policyContentType()) + "}");
        conditions.add("{\"success_action_status\":\"201\"}");
        conditions.add("[\"content-length-range\",1," + s.maxBytes() + "]");
        conditions.add("{\"x-amz-algorithm\":\"AWS4-HMAC-SHA256\"}");
        conditions.add("{\"x-amz-credential\":" + q(credential) + "}");
        conditions.add("{\"x-amz-date\":" + q(amzDate) + "}");
        if (s.includeToken()) {
            conditions.add("{\"x-amz-security-token\":" + q(c.token()) + "}");
        }
        String policyJson = "{\"expiration\":" + q(expiration)
                + ",\"conditions\":[" + String.join(",", conditions) + "]}";
        String policyB64 = Base64.getEncoder()
                .encodeToString(policyJson.getBytes(StandardCharsets.UTF_8));

        String signature = HexFormat.of().formatHex(hmac(signingKey(c.secretKey(), date), policyB64));

        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("key", s.formKey());
        fields.put("Content-Type", s.formContentType());
        fields.put("success_action_status", "201");
        fields.put("x-amz-algorithm", "AWS4-HMAC-SHA256");
        fields.put("x-amz-credential", credential);
        fields.put("x-amz-date", amzDate);
        if (s.includeToken()) {
            fields.put("x-amz-security-token", c.token());
        }
        fields.put("policy", policyB64);
        fields.put("x-amz-signature", signature);

        String url = "https://" + bucket + ".s3." + REGION + ".amazonaws.com/";
        return new Signed(url, fields, policyJson);
    }

    /** Cadena HMAC de SigV4: fecha -> region -> servicio -> "aws4_request". */
    static byte[] signingKey(String secret, String date) {
        byte[] kDate = hmac(("AWS4" + secret).getBytes(StandardCharsets.UTF_8), date);
        byte[] kRegion = hmac(kDate, REGION);
        byte[] kService = hmac(kRegion, "s3");
        return hmac(kService, "aws4_request");
    }

    static byte[] hmac(byte[] key, String data) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(data.getBytes(StandardCharsets.UTF_8));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    /** String JSON minimo (los valores son controlados, solo escapamos \ y "). */
    public static String q(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }
}
