# Cloud Infrastructure Architecture (Revision 4)

## 1. Architectural Overview & Rationale
This is a **Cost-Optimized Cloud-Native Architecture** (~$25-$30 USD/month), not strictly serverless: it runs one 24/7 container and one relational database. It uses Public Subnets with strict Security Groups (SGs) to avoid ~$35/month NAT Gateway charges, and compensates with tight IAM, lifecycle policies and cost controls.

## 2. IaC Stacks
Two independent OpenTofu stacks:

* **`bootstrap` stack (applied once, never destroyed with the app):**
  * S3 state bucket: versioning on, Block Public Access on, SSE-S3 encryption, bucket policy denying non-TLS access, access limited to the infra role and the human admin.
  * GitHub OIDC identity provider.
  * The two CI IAM roles (see section 7).
  * **AWS Budget** of $30 with email notifications at 80% and 100% (actual) plus a forecast alert, using the Budget's native email subscribers (no SNS topic needed). It lives here so cost protection is active before anything else is created and survives every destroy of the app.
* **`main` stack:** everything else (VPC, ECS, RDS, S3 app buckets, CloudFront, pipeline). This is the stack that `tofu destroy` removes.

## 3. Network & Compute Layer
* **VPC & Subnets:**
  * Custom VPC with **public subnets only**, spanning **2 AZs** (required by the RDS subnet group and useful for future growth).
  * Internet Gateway; no NAT Gateway.
* **Compute (ECS Fargate Spot only):**
  * Capacity provider: `FARGATE_SPOT` only, desired count 1. The provider must be associated with the cluster (`aws_ecs_cluster_capacity_providers`) and the service must reference it in its `capacity_provider_strategy`.
  * Task size: **0.5 vCPU / 1 GB RAM** (Spring Boot needs the 1 GB).
  * Public IPv4 auto-assigned (~$3.60/month per IP; a rolling deploy briefly uses two).
  * **Accepted trade-off:** a Spot interruption or lack of Spot capacity causes minutes of downtime. SQS buffers events meanwhile, so no state updates are lost.
  * *Security:* ECS SG denies all ingress except from the API Gateway VPC Link SG on the app port. Outbound open (ECR, Google JWKS, SQS, SSM).
  * *Deploys:* `deployment_minimum_healthy_percent = 100`, `deployment_maximum_percent = 200`.
  * *Health check:* ECS container health check (no ALB). The image must explicitly include `curl` (or `wget`), since slim Java images usually lack both. Command: `CMD-SHELL curl -f http://localhost:8080/api/actuator/health || exit 1`, with a `startPeriod` of ~60-90 s for JVM startup. Actuator health is exposed but not other actuator endpoints.
* **Ingress (API Gateway HTTP API):**
  * Routes: `ANY /api/{proxy+}` **and** `ANY /api` (`{proxy+}` does not match the bare `/api`), both to the same integration.
  * Integration: `HTTP_PROXY`, `connection_type = VPC_LINK`, `integration_uri` = the **Cloud Map service ARN**. The VPC Link lives in the public subnets with its own security group (the one the ECS SG trusts).
  * The `/api` prefix reaches the container unchanged, so Spring Boot runs with `server.servlet.context-path=/api`.
  * Cloud Map: private DNS namespace plus a service with an **SRV record** (routing policy `MULTIVALUE`, short TTL). The ECS service registers with `service_registries` including the container port. The private namespace creates a Route 53 private hosted zone (~$0.50/month).
  * Throttling is per route/stage only. Per-user limits live in the application.
* **Database (RDS PostgreSQL `db.t4g.micro`, Single-AZ):**
  * Placed in the public subnets but with `publicly_accessible = false`.
  * DB subnet group across 2 AZs.
  * RDS SG allows ingress only from the ECS SG on 5432.
  * `skip_final_snapshot = true`, `deletion_protection = false`.

## 4. Storage, CDN, and Frontend Delivery
* **S3 Buckets (all private, Block Public Access on, `force_destroy = true`):**
  * `frontend-hosting`: Next.js static export.
  * `raw-videos`: Presigned POST uploads under `raw/{videoId}.mp4`. **CORS** allows `POST` from the frontend origin only. Lifecycle rule: delete objects after 7 days.
  * `processed-videos`: HLS output and thumbnails, stored under the prefix **`videos/{videoId}/`** so the CloudFront path `/videos/*` maps 1:1 to the bucket keys.
  * **Bucket policies for `frontend-hosting` and `processed-videos`:** allow the service principal `cloudfront.amazonaws.com` to `s3:GetObject` on `bucket/*` **and** `s3:ListBucket` on the bucket, with condition `StringEquals AWS:SourceArn = <distribution ARN>`. `ListBucket` makes a missing object return **404** instead of 403. Create the policy after the Block Public Access resource (`depends_on`) to avoid conflicting concurrent updates.
* **Amazon CloudFront (single distribution, OAC for both S3 origins):**
  * Origins use each bucket's **regional domain name** with OAC (`signing_behavior = always`, `sigv4`).
  * **Default `(*)` → `frontend-hosting`:** cache policy `Managed-CachingOptimized`.
    * Next.js config: `output: 'export'`, `trailingSlash: true`. Video page is `/watch/?v=<id>`.
    * A **CloudFront Function (viewer-request, `cloudfront-js-2.0`)** attached to this behavior only: if the URI ends with `/`, append `index.html`; else if the last path segment has no `.`, append `/index.html`. Paths with a file extension are not rewritten. Do not set `default_root_object`; the function handles `/`.
    * **No global Custom Error Responses** (403/404 → `index.html`), because they apply to the whole distribution and would mask real API and HLS errors.
  * **`/api/*` → API Gateway** (custom origin: the API's default endpoint, HTTPS only, TLS 1.2; viewer protocol HTTPS only; all HTTP methods allowed):
    * Cache policy: `Managed-CachingDisabled`.
    * Origin request policy: **`Managed-AllViewerExceptHostHeader`** (forwards `Authorization` without forwarding the viewer `Host`, which makes API Gateway return 403). API Gateway then sees its own host and the original `Authorization` header.
    * The `/api` prefix reaches the origin unchanged (hence Spring `context-path=/api`).
  * **`/videos/*` → `processed-videos`:**
    * Cache policy `Managed-CachingOptimized`.
    * Response Headers Policy with CORS (`GET`/`HEAD`/`OPTIONS`, `origin_override = true`) allowing only the **local development origin** (`http://localhost:3000`). In production the site and the videos share the CloudFront domain, so `hls.js` requests are same-origin and need no CORS; requests from any other origin receive no CORS header.
    * Caching: long TTL for `.ts` segments; short TTL for `.m3u8` manifests.

## 5. Asynchronous Video Pipeline (Event-Driven)

### 5.1 Message contract (SQS)
Both producers write the same envelope to a single Standard queue:
```json
{ "type": "PROCESSING_STARTED | TRANSCODE_COMPLETE | TRANSCODE_ERROR",
  "videoId": "<uuid>", "occurredAt": "<iso8601>" }
```
The Lambda produces `PROCESSING_STARTED`. For MediaConvert events there are **two EventBridge rules, one per status**, because an input transformer cannot translate a value (`COMPLETE` → `TRANSCODE_COMPLETE`); the `type` is a literal in each rule's template:
* Input paths: `videoId = $.detail.userMetadata.videoId`, `time = $.time`.
* `COMPLETE` rule template: `{"type":"TRANSCODE_COMPLETE","videoId":"<videoId>","occurredAt":"<time>"}`.
* `ERROR` rule template: `{"type":"TRANSCODE_ERROR","videoId":"<videoId>","occurredAt":"<time>"}`.

### 5.2 Flow
1. **Trigger:** `s3:ObjectCreated:Post` on `raw-videos` (prefix `raw/`, suffix `.mp4`) invokes the Lambda.
2. **Lambda:**
   * Parses and validates `videoId` (UUID) from the key.
   * Calls MediaConvert `CreateJob` with **`ClientRequestToken = videoId`** (a duplicate S3 event cannot create a second job) and `UserMetadata.videoId`.
   * Sends `PROCESSING_STARTED` to SQS.
   * IAM: `s3:GetObject` on `raw/*`, `mediaconvert:CreateJob`, `sqs:SendMessage` on the queue, **`iam:PassRole`** restricted to the MediaConvert role.
   * Failure handling: asynchronous invocation **OnFailure destination (or DLQ)** configured, with a CloudWatch alarm.
3. **MediaConvert:** few renditions (cost scales per rendition), outputs HLS to `s3://processed-videos/videos/{videoId}/` and extracts a thumbnail.
4. **EventBridge rules (two):** each matches `source = aws.mediaconvert`, `detail-type = MediaConvert Job State Change`, `detail.status` = `COMPLETE` (or `ERROR`), and `detail.userMetadata.videoId` exists (`{"exists": true}`). Events without `videoId` or with other statuses (e.g. `PROGRESSING`) are not delivered. Target: the SQS queue, with the input transformer from 5.1.
5. **SQS (Standard):** resource policy allows `events.amazonaws.com` `sqs:SendMessage` with condition `ArnEquals aws:SourceArn` listing **both rule ARNs**. Queue settings: `visibility_timeout_seconds` greater than the consumer's processing time (e.g. 60), long polling (`receive_wait_time_seconds = 20`). Attached **DLQ** via redrive policy (`maxReceiveCount` ~5; a message moves to the DLQ when it would be received more times than that). **CloudWatch Alarm** on the DLQ: `AWS/SQS` `ApproximateNumberOfMessagesVisible` > 0, period 60 s, `treat_missing_data = notBreaching`, action = SNS topic with an email subscription (the subscription must be confirmed from the email).
6. **Consumer (Spring Boot `@SqsListener`):**
   * Standard SQS is at-least-once and unordered, so the consumer is **idempotent** and applies **monotonic transitions** (see section 6).
   * Unknown `videoId`: log, acknowledge and discard (never retry into the DLQ).
7. **Limbo recovery:** `@Scheduled` job marks videos stuck in `UPLOADING` or `PROCESSING` for more than 2 hours as `FAILED` using a **conditional UPDATE**, so two instances running during a rolling deploy are harmless. Marking `FAILED` also releases the user's quota reservation.

## 6. Video State Rules
* Order: `UPLOADING` < `PROCESSING` < `READY`. `FAILED` is a side state.
* Rules, enforced in SQL (`UPDATE ... WHERE status IN (...)`):
  * `PROCESSING_STARTED`: only applies if current status is `UPLOADING`.
  * `TRANSCODE_COMPLETE`: applies from `UPLOADING`, `PROCESSING` **or `FAILED`** (a late success overrides a cron timeout), never downgrades from `READY`.
  * `TRANSCODE_ERROR`: applies from `UPLOADING` or `PROCESSING`; never overrides `READY`.
  * Cron: only `UPLOADING`/`PROCESSING` older than 2 hours → `FAILED`.
* This makes `READY` arriving before `PROCESSING` (backend was down) harmless.

## 7. Infrastructure as Code & CI/CD
* **Remote state:** S3 bucket from the `bootstrap` stack, OpenTofu 1.10+ native locking (`use_lockfile = true`), SSE-S3. The state holds plaintext generated secrets (RDS password), so the bucket is tightly restricted.
* **Generated secrets:** RDS password is written to the state and to SSM Parameter Store (SecureString, default key) only. Outputs carrying secrets must be `sensitive = true`; never log or duplicate them.
* **GitHub Actions via OIDC (no static keys), two roles:**
  * **`app-deploy` role:** trust `sub = repo:Org/Repo:ref:refs/heads/main`, `aud = sts.amazonaws.com`. Permissions: ECR push, `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `iam:PassRole` only for the task and execution roles, S3 sync and CloudFront invalidation on the frontend bucket.
  * **`infra` role:** trust `sub = repo:Org/Repo:environment:infra`, `aud = sts.amazonaws.com`. The GitHub Environment `infra` requires **manual approval**. Since `tofu apply` creates IAM resources, this role is effectively admin: the approval gate, a permissions boundary and the exact `sub` are the mitigations.
* **Operational controls:** CloudWatch log retention 7 days; ECR lifecycle policy for untagged/old images.

## 8. Identity & Security Notes
* Spring Security Resource Server validates signature (Google JWKS), **issuer** (`https://securetoken.google.com/<project-id>`) and **audience** (`<project-id>`).
* ECS uses **two roles**:
  * **Execution role** (used by ECS to start the task): ECR pull, CloudWatch Logs, and `ssm:GetParameters` on the app parameters, because secrets declared in the task definition's `secrets` field are resolved at task start by this role, not by the task role.
  * **Task role** (used by the application, least privilege): `s3:PutObject` on `raw-videos/raw/*` (needed for the presigned POST to be valid), and `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on the pipeline queue.
* Presigned POST policy conditions: `bucket`, fixed `key`, `content-length-range`, `Content-Type`, `success_action_status`, `x-amz-algorithm`, `x-amz-credential`, `x-amz-date`, `x-amz-security-token`, short expiration (e.g. 5 minutes). Every form field sent (except `file`, `policy` and `x-amz-signature`) must have a matching condition, and `x-amz-security-token` must be both a form field and a condition (the task role uses temporary credentials). The `file` field goes last in the form.
* S3 CORS on `raw-videos` is only a browser convenience (response readability for one origin); it is not an access control. The real controls are the signed policy and the least-privilege role.

## 9. Estimated Monthly Cost
| Item | Approx. USD |
|---|---|
| RDS `db.t4g.micro` + storage | 12-15 |
| Fargate Spot (0.5 vCPU / 1 GB) | 5-8 |
| Public IPv4 | ~3.6 |
| Cloud Map private DNS namespace (Route 53 hosted zone) | ~0.5 |
| S3, CloudFront, logs, SQS, Lambda | ~2 |
| MediaConvert | usage-based (the main variable) |
| **Total (excluding MediaConvert)** | **~25** |

RDS free tier eligibility depends on account age and the current AWS free tier terms; verify for your account.
