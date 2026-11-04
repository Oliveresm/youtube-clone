terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "me" {}

locals {
  account = data.aws_caller_identity.me.account_id
}

# ---------------------------------------------------------------
# 1. Buckets privados (frontend y videos procesados)
# ---------------------------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket        = "spike4-frontend-${local.account}"
  force_destroy = true
}

resource "aws_s3_bucket" "videos" {
  bucket        = "spike4-videos-${local.account}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "videos" {
  bucket                  = aws_s3_bucket.videos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------
# 2. Contenido de prueba (imita un export de Next.js con trailingSlash)
# ---------------------------------------------------------------
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"
  content      = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>home</title></head><body><h1>HOME PAGE (index.html)</h1><a href=\"/watch/?v=abc\">ir a watch</a></body></html>"
}

resource "aws_s3_object" "watch" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "watch/index.html"
  content_type = "text/html"
  content      = <<-EOT
    <!DOCTYPE html>
    <html>
    <head><meta charset="utf-8"><title>watch</title></head>
    <body>
      <h1>WATCH PAGE (watch/index.html)</h1>
      <p>Parametro v = <b id="v"></b></p>
      <p>Respuesta de /api/hello:</p>
      <pre id="api">cargando...</pre>
      <script src="/assets/app.js"></script>
    </body>
    </html>
  EOT
}

resource "aws_s3_object" "appjs" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "assets/app.js"
  content_type = "application/javascript"
  content      = <<-EOT
    document.addEventListener('DOMContentLoaded', function () {
      var v = new URLSearchParams(location.search).get('v');
      document.getElementById('v').textContent = v;
      fetch('/api/hello', { headers: { Authorization: 'Bearer test123' } })
        .then(function (r) { return r.text().then(function (t) { return r.status + ' ' + t; }); })
        .then(function (t) { document.getElementById('api').textContent = t; })
        .catch(function (e) { document.getElementById('api').textContent = 'ERROR ' + e; });
    });
  EOT
}

resource "aws_s3_object" "manifest" {
  bucket       = aws_s3_bucket.videos.id
  key          = "videos/test/index.m3u8"
  content_type = "application/vnd.apple.mpegurl"
  content      = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
}

resource "aws_s3_object" "segment" {
  bucket       = aws_s3_bucket.videos.id
  key          = "videos/test/seg0.ts"
  content_type = "video/mp2t"
  content      = "FAKE-TS-SEGMENT"
}

# ---------------------------------------------------------------
# 3. Backend de prueba: API Gateway + Lambda que "hace eco" de la peticion
#    (la ruta VPC Link -> Fargate ya se valido en el spike 1)
# ---------------------------------------------------------------
data "archive_file" "echo" {
  type        = "zip"
  output_path = "${path.module}/echo.zip"
  source {
    filename = "index.py"
    content  = <<-EOT
      import json

      def handler(event, context):
          path = event.get("rawPath", "")
          headers = event.get("headers", {})
          status = 404 if path.endswith("/notfound") else 200
          body = {
              "rawPath": path,
              "method": event["requestContext"]["http"]["method"],
              "host": headers.get("host"),
              "authorization": headers.get("authorization"),
          }
          return {
              "statusCode": status,
              "headers": {"content-type": "application/json"},
              "body": json.dumps(body),
          }
    EOT
  }
}

resource "aws_iam_role" "lambda" {
  name = "spike4-echo-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "echo" {
  function_name    = "spike4-echo"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.echo.output_path
  source_code_hash = data.archive_file.echo.output_base64sha256
}

resource "aws_apigatewayv2_api" "api" {
  name          = "spike4-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "echo" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.echo.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "ANY /api/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.echo.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.echo.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ---------------------------------------------------------------
# 4. CloudFront: OAC + Function (solo behavior por defecto) + 3 behaviors
# ---------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "spike4-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "rewrite" {
  name    = "spike4-index-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      var last = uri.split('/').pop();
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
      } else if (last.indexOf('.') === -1) {
        request.uri = uri + '/index.html';
      }
      return request;
    }
  EOT
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# CORS para /videos/*: solo necesario si el sitio se sirve desde OTRO origen
# (p. ej. localhost:3000 en desarrollo). En produccion el sitio y los videos
# comparten dominio de CloudFront, asi que no hay peticion cross-origin.
resource "aws_cloudfront_response_headers_policy" "cors" {
  name = "spike4-hls-cors"
  cors_config {
    access_control_allow_credentials = false
    origin_override                  = true
    access_control_allow_headers {
      items = ["*"]
    }
    access_control_allow_methods {
      items = ["GET", "HEAD", "OPTIONS"]
    }
    access_control_allow_origins {
      items = ["http://localhost:3000"]
    }
  }
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled     = true
  comment     = "spike4"
  price_class = "PriceClass_100"

  origin {
    origin_id                = "frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  origin {
    origin_id                = "videos"
    domain_name              = aws_s3_bucket.videos.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  origin {
    origin_id   = "api"
    domain_name = replace(aws_apigatewayv2_api.api.api_endpoint, "https://", "")
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
    compress               = true

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  ordered_cache_behavior {
    path_pattern               = "/videos/*"
    target_origin_id           = "videos"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.cors.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ---------------------------------------------------------------
# 5. Politicas de bucket: solo esta distribucion puede leer.
#    s3:ListBucket hace que un objeto inexistente responda 404 (y no 403).
# ---------------------------------------------------------------
data "aws_iam_policy_document" "frontend" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.frontend.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

data "aws_iam_policy_document" "videos" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.videos.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.videos.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket     = aws_s3_bucket.frontend.id
  policy     = data.aws_iam_policy_document.frontend.json
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

resource "aws_s3_bucket_policy" "videos" {
  bucket     = aws_s3_bucket.videos.id
  policy     = data.aws_iam_policy_document.videos.json
  depends_on = [aws_s3_bucket_public_access_block.videos]
}

output "cdn_url" {
  value = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

# URL directa al bucket (debe responder 403: solo CloudFront puede leer)
output "frontend_direct_url" {
  value = "https://${aws_s3_bucket.frontend.bucket_regional_domain_name}"
}
