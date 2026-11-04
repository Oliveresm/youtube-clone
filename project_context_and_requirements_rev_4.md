# Project Context and Requirements: Cost-Optimized Cloud-Native YouTube Clone (Revision 4)

This document says **what** the system must do and how it is accepted. **How** it is built on AWS (resources, policies, roles, message contract, state rules) lives in `cloud_infrastructure_architecture_rev_4.md`; this document only refers to it by section ("arch §N") and does not repeat it.

## 1. System Context
**Note for AI Assistant/Reviewers:** This document describes a portfolio project that showcases event-driven cloud architecture, backend resilience and modern IaC practices. Because it uses a 24/7 container and a relational database, it is defined as a **Cost-Optimized Cloud-Native Architecture** (~$25-$30/month, excluding MediaConvert usage), not strictly "serverless".

The application is a video streaming platform using adaptive bitrate streaming (HLS). It prioritizes operational controls, abuse prevention and infrastructure lifecycle management over happy-path implementations.

## 2. Technology Stack
* **Frontend:** Next.js (React), Tailwind CSS, TypeScript, static export. Video route uses a query parameter (`/watch/?v=<id>`); no dynamic route segments.
* **Backend:** Spring Boot (Java 17/21), Spring Security (OAuth2 Resource Server), `io.awspring.cloud` for SQS.
* **Database:** PostgreSQL on Amazon RDS.
* **Authentication:** Firebase Authentication (JWT).
* **Cloud / IaC / CI:** AWS; OpenTofu 1.10+ split into `bootstrap` and `main` stacks; GitHub Actions with AWS OIDC (arch §2, §7).

## 3. Core Functional Requirements

### 3.1 Authentication & Authorization
* Firebase Auth on the client; the frontend sends `Authorization: Bearer <token>`.
* The backend validates the token (signature, issuer, audience; arch §8). No Firebase Admin SDK and no service account. The user UID is the JWT `sub`.
* Per-user rate limiting, if needed, is implemented in the application.

### 3.2 Secure Video Uploading (Direct-to-Cloud)
1. Client requests an upload, declaring file size and type.
2. Backend, in **one DB transaction with a row lock**, checks the user's quota and **reserves** the declared bytes, then creates the video record (`UPLOADING`).
3. Backend returns an **S3 Presigned POST**, signed manually with SigV4 (conditions in arch §8). The upper bound of `content-length-range` equals the declared (reserved) size.
4. Frontend POSTs the file directly to the private raw bucket; the backend never handles the file.
5. The reservation is **released** if the video becomes `FAILED` or the upload never completes.

**Cost-abuse controls (explicit decision):** video duration cannot be known before signing, and MediaConvert bills per minute per rendition. Therefore duration is *not* enforced. Compensating controls: maximum file size per upload (e.g. 500 MB), maximum uploads per user per day, monthly byte quota, a small fixed number of renditions, and the AWS Budget alerts.

### 3.3 Transcoding and State Tracking
* An upload starts in `UPLOADING`. The S3 event triggers a Lambda that idempotently starts a MediaConvert job and reports `PROCESSING_STARTED` (arch §5.2).
* MediaConvert writes HLS and a thumbnail to the processed bucket under `videos/{videoId}/`.
* The backend consumes status events from SQS with idempotent, monotonic transitions (message contract arch §5.1, rules arch §6). Unknown `videoId`: acknowledge and discard.
* Videos stuck in `UPLOADING` or `PROCESSING` for more than 2 hours become `FAILED` through a conditional UPDATE, releasing their quota reservation.
* Failures in the DLQ or in the Lambda notify the owner by email (arch §5.3).

### 3.4 Video Playback
* `hls.js` (or `video.js`) streams from CloudFront under `/videos/*`. In production the site and videos share the CloudFront domain (same-origin). CORS details: arch §4.

## 4. Non-Functional & Operational Requirements

### 4.1 Cost Control
* An AWS Budget with email alerts is active from day one and survives app destroys (arch §2).
* Fargate Spot only, single task. Brief downtime on Spot interruption is accepted; SQS prevents event loss.

### 4.2 Infrastructure Lifecycle
* The `main` stack must be fully destroyable with `tofu destroy` and no manual cleanup (buckets and ECR forced to empty, RDS without final snapshot or deletion protection; arch §3, §4).
* The `bootstrap` stack is separate and is not destroyed with the app.
* Log groups have 7-day retention; ECR has a lifecycle policy; the raw video bucket expires objects after 7 days.

### 4.3 Security & Secrets
* All S3 buckets are private; CloudFront reads them through OAC only (arch §4).
* RDS is not publicly accessible; the ECS service accepts traffic only from the API Gateway VPC Link (arch §3).
* ECS uses separate execution and task roles with least privilege (arch §8).
* CI/CD uses OIDC with two roles and no static IAM keys (arch §7).
* Application secrets come from SSM Parameter Store; non-secret configuration is passed as environment variables (arch §8). Infrastructure-generated secrets live in the restricted remote state, and outputs containing them are `sensitive = true`.

## 5. Acceptance Checks
1. API Gateway → VPC Link → Cloud Map (SRV) → Fargate works with the SG restriction and the `/api` context path.
2. Browser Presigned POST succeeds with temporary credentials, rejects oversize files and wrong keys, and S3 CORS works.
3. `/watch/?v=<id>` loads through CloudFront (Function + OAC); a missing `.m3u8` or API 404 returns a real 404, not HTML with 200.
4. Duplicate S3 events and duplicate/out-of-order SQS messages leave the video in the correct final state.
5. `tofu destroy` of `main` completes without manual cleanup.
6. MediaConvert `COMPLETE`/`ERROR` events reach the SQS queue in the message-contract shape; events without `videoId` are not delivered.
7. A message that exhausts its receive count lands in the DLQ, the CloudWatch alarm fires and the email from the `alerts` topic is received.
