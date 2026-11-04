# Project Context and Requirements: Cost-Optimized Cloud-Native YouTube Clone (Revision 4)

## 1. System Context
**Note for AI Assistant/Reviewers:** This document describes a portfolio project that showcases event-driven cloud architecture, backend resilience and modern IaC practices. Because it uses a 24/7 container and a relational database, it is defined as a **Cost-Optimized Cloud-Native Architecture** (~$25-$30/month, excluding MediaConvert usage), not strictly "serverless".

The application is a video streaming platform using adaptive bitrate streaming (HLS). It prioritizes operational controls, abuse prevention and infrastructure lifecycle management over happy-path implementations.

## 2. Technology Stack
* **Frontend:** Next.js (React), Tailwind CSS, TypeScript. Static export (`output: 'export'`, `trailingSlash: true`). Video route uses a query parameter: `/watch/?v=<id>`. No dynamic route segments and no global CloudFront error-to-`index.html` rewrite.
* **Backend:** Spring Boot (Java 17/21), Spring Security (OAuth2 Resource Server), `io.awspring.cloud` for SQS. `server.servlet.context-path=/api`. Container: 0.5 vCPU / 1 GB RAM, image includes `curl` for the container health check.
* **Database:** PostgreSQL on Amazon RDS (`db.t4g.micro`, not publicly accessible).
* **Authentication:** Firebase Authentication (JWT).
* **Cloud Provider:** AWS.
* **IaC:** OpenTofu 1.10+ (native S3 state locking), split into `bootstrap` and `main` stacks.
* **CI/CD:** GitHub Actions with AWS OIDC, two separate roles.

## 3. Core Functional Requirements

### 3.1 Authentication & Authorization
* Firebase Auth on the client; the frontend sends `Authorization: Bearer <token>`.
* The backend validates signature (Google JWKS), **issuer** (`https://securetoken.google.com/<project-id>`) and **audience** (`<project-id>`). No Firebase Admin SDK, no service account. The user UID is the JWT `sub`.
* Per-user rate limiting, if needed, is implemented in the application (API Gateway throttling is per route/stage only).

### 3.2 Secure Video Uploading (Direct-to-Cloud)
1. Client requests an upload, declaring file size and type.
2. Backend, in **one DB transaction with a row lock**, checks the user's quota and **reserves** the declared bytes, then creates the video record (`UPLOADING`).
3. Backend returns an **S3 Presigned POST** (manually signed with SigV4) whose policy contains:
   * fixed `key = raw/{videoId}.mp4` (no wildcards or `starts-with`),
   * `content-length-range` with the upper bound equal to the declared (reserved) size,
   * `Content-Type` condition,
   * `x-amz-security-token` (task role uses temporary credentials; it is both a form field and a policy condition),
   * a condition for every other form field sent (S3 rejects fields without a matching condition),
   * short expiration (e.g. 5 minutes).
4. Frontend POSTs the file directly to the private raw bucket (S3 CORS allows `POST` from the site origin only; CORS is a browser convenience, not access control: the signed policy and the least-privilege role are the real controls).
5. The reservation is **released** if the video becomes `FAILED` or the upload never completes.

**Cost-abuse controls (explicit decision):** video duration cannot be known before signing, and MediaConvert bills per minute per rendition. Therefore duration is *not* enforced. Compensating controls: maximum file size per upload (e.g. 500 MB), maximum uploads per user per day, monthly byte quota, a small fixed number of renditions, and the AWS Budget alerts.

### 3.3 Resilient Video Transcoding (State Machine)
* Upload starts in `UPLOADING`.
* S3 event (`ObjectCreated:Post`, prefix `raw/`, suffix `.mp4`) triggers a Lambda that:
  1. validates `videoId` (UUID) from the key,
  2. submits the MediaConvert job with `ClientRequestToken = videoId` and `UserMetadata.videoId` (idempotent),
  3. publishes `PROCESSING_STARTED` to SQS.
* The Lambda has a failure destination/DLQ with an alarm.
* MediaConvert writes HLS and a thumbnail to `processed-videos` under `videos/{videoId}/`.

### 3.4 State Reconciliation & Limbo Recovery
* **Two EventBridge rules, one per status** (`COMPLETE` → `TRANSCODE_COMPLETE`, `ERROR` → `TRANSCODE_ERROR`), each matching `aws.mediaconvert`, the status and `userMetadata.videoId` present. Each uses an input transformer with a literal `type` to produce the message contract below and sends to the same SQS queue. Events without `videoId` or with other statuses are not delivered.
* **Message contract:** `{ "type": "PROCESSING_STARTED | TRANSCODE_COMPLETE | TRANSCODE_ERROR", "videoId": "<uuid>", "occurredAt": "<iso8601>" }`.
* Spring Boot consumes with `@SqsListener`. The consumer MUST be idempotent and enforce monotonic transitions via conditional SQL updates:
  * `PROCESSING_STARTED`: only from `UPLOADING`.
  * `TRANSCODE_COMPLETE`: from `UPLOADING`, `PROCESSING` or `FAILED`; never downgrades `READY`.
  * `TRANSCODE_ERROR`: from `UPLOADING` or `PROCESSING`; never overrides `READY`.
* Unknown `videoId`: log, acknowledge and discard (do not retry to the DLQ).
* **Cron (`@Scheduled`):** videos in `UPLOADING` or `PROCESSING` for more than 2 hours become `FAILED` through a conditional UPDATE (safe if two instances overlap during a deploy), and their quota reservation is released.
* DLQ depth > 0 triggers a CloudWatch alarm with SNS email.

### 3.5 Video Playback
* `hls.js` (or `video.js`) streams from CloudFront under `/videos/*`. In production the site and videos share the CloudFront domain (same-origin, no CORS needed). A Response Headers Policy allows only the local development origin (`http://localhost:3000`).

## 4. Non-Functional & Operational Requirements

### 4.1 Cost Control
* OpenTofu provisions an AWS Budget in the **`bootstrap` stack** with email notifications (native Budget subscribers, no SNS topic) at 80% and 100% of $30 (actual) plus a forecast alert, so it is active from day one and survives app destroys.
* Fargate Spot only, single task. Brief downtime on Spot interruption is accepted; SQS prevents event loss.

### 4.2 Infrastructure Lifecycle (Clean Destroys)
* `bootstrap` stack (state bucket, OIDC provider, CI roles, Budget) is separate and is not destroyed with the app.
* In `main`: S3 buckets `force_destroy = true`, ECR `force_delete = true`, RDS `skip_final_snapshot = true` and `deletion_protection = false`.
* ECR lifecycle policy for untagged/old images.
* CloudWatch Log Groups with 7-day retention.
* Raw video bucket lifecycle rule: delete after 7 days.

### 4.3 Security & Secrets
* All S3 buckets private with Block Public Access; CloudFront uses OAC. Bucket policies grant `s3:GetObject` and `s3:ListBucket` only to the distribution (`AWS:SourceArn` condition), so missing objects return 404 and direct S3 access returns 403.
* ECS uses two roles: an **execution role** (ECR pull, logs, SSM secrets resolved at task start) and a **task role** (application permissions: `s3:PutObject` on `raw/*`, SQS receive/delete/get-attributes on the pipeline queue).
* RDS not publicly accessible; ingress only from the ECS security group.
* ECS security group accepts ingress only from the API Gateway VPC Link security group.
* **CI/CD:** no static IAM keys. Two OIDC roles, both with `aud = sts.amazonaws.com`:
  * `app-deploy`: `sub = repo:Org/Repo:ref:refs/heads/main`; minimal permissions (ECR push, ECS task definition/service update, `iam:PassRole` for task roles only, frontend S3 sync, CloudFront invalidation).
  * `infra`: `sub = repo:Org/Repo:environment:infra`; the GitHub Environment requires manual approval; permissions boundary applied, since `tofu apply` creates IAM resources.
* **Secrets:** application secrets injected at runtime from **SSM Parameter Store** (SecureString, default key). Infrastructure-generated secrets (RDS password) live in the encrypted-at-rest, access-restricted remote state; outputs containing them are `sensitive = true`.

## 5. Acceptance Checks
1. API Gateway → VPC Link → Cloud Map (SRV) → Fargate works with the SG restriction and the `/api` context path.
2. Browser Presigned POST succeeds with temporary credentials, rejects oversize files and wrong keys, and S3 CORS works.
3. `/watch/?v=<id>` loads through CloudFront (Function + OAC); a missing `.m3u8` or API 404 returns a real 404, not HTML with 200.
4. Duplicate S3 events and duplicate/out-of-order SQS messages leave the video in the correct final state.
5. `tofu destroy` of `main` completes without manual cleanup.
6. MediaConvert `COMPLETE`/`ERROR` events reach the SQS queue in the message-contract shape; events without `videoId` are not delivered.
7. A message that exhausts its receive count lands in the DLQ, the CloudWatch alarm fires and the SNS email is received.
