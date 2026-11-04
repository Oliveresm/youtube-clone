# Implementation Plan: Cloud-Native YouTube Clone

Working rules, repository layout and hard constraints live in `AGENTS.md`. Design details live in `cloud_infrastructure_architecture_rev_4.md` and `project_context_and_requirements_rev_4.md`. This file only orders the work.

How to use it:
* One task at a time, in order, on its own branch (`<agent>/<task-id>`).
* A task is done only when its **Done when** criteria are verified with real command output.
* Agents never run `tofu apply`/`destroy` or AWS write commands; the user does, after reviewing the plan.

Status legend: DONE, NEXT, TODO.

---

## Phase 0: Repository setup: DONE
Repo `Oliveresm/youtube-clone` created, `.gitignore`, `AGENTS.md`, `CLAUDE.md`, both design documents and the validated spikes are committed.

## Phase 2: Spikes: DONE
Validated and destroyed. Findings are already merged into the design documents. The code stays in `spikes/` as reference only.

| Spike | What it proved |
|---|---|
| 1 | API Gateway → VPC Link → Cloud Map (SRV) → Fargate Spot in public subnets; direct access to the task's public IP is blocked; `/api` prefix arrives intact. |
| 2 | Presigned POST signed by hand in Java with temporary credentials; oversize, wrong key, wrong content type, expired, missing token and out-of-prefix uploads are rejected. |
| 3 | A Fargate task in a public subnet can pull from ECR, write logs and consume SQS with a scoped task role. |
| 4 | CloudFront with OAC, Function for `/watch/?v=<id>`, real 404s, `/api/*` with `AllViewerExceptHostHeader`, `/videos/*` CORS only for allowed origins, direct S3 access blocked. |
| 5 | EventBridge → SQS with input transformer, filters and DLQ. **The CloudWatch alarm → SNS email path was not verified**; it is acceptance check 7. |

---

## Phase 1: Bootstrap stack (applied manually, once): NEXT
Prerequisites (user): note the Firebase project ID (Authentication enabled; no service account needed) and the email address for budget alerts.

**T1.1 State bucket.**
Create the state bucket in `infra/bootstrap` with versioning, Block Public Access, SSE-S3, a policy denying non-TLS access and access limited to the admin and (later) the infra role. The bucket created by hand earlier (`youtube-clone-403732031115`) is empty: delete it and let this stack create the bucket (suggested name `youtube-clone-tfstate-<account-id>`), unless the user prefers to import it.
*Done when:* `tofu plan` shows the bucket with all those settings and, after the user applies, they are visible in the console.

**T1.2 AWS Budget.**
$30 budget with email notifications at 80% and 100% (actual) plus a forecast alert, using the Budget's native email subscribers (no SNS topic). The email address is a variable (`budget_email`), set in a non-committed `terraform.tfvars`.
*Done when:* the budget appears in the console with the three notifications and the user's email listed as a subscriber.

**T1.3 GitHub OIDC provider and CI roles.**
OIDC provider; `app-deploy` role (`sub = repo:Oliveresm/youtube-clone:ref:refs/heads/main`) and `infra` role (`sub = repo:Oliveresm/youtube-clone:environment:infra`), both with `aud = sts.amazonaws.com`. Minimal permissions per the architecture document; permissions boundary on the `infra` role.
*Done when:* a test workflow assumes each role from the right branch/environment and is denied from any other.

**T1.4 GitHub Environment.**
Create the `infra` environment with required manual approval.
*Done when:* a workflow that uses it pauses for approval.

**T1.5 Bootstrap state location.**
The bootstrap stack starts with local state (never committed). Once the bucket exists, migrate it with `tofu init -migrate-state` to the bucket under key `bootstrap/terraform.tfstate`. The `main` stack uses key `main/terraform.tfstate` with `use_lockfile = true`.
*Done when:* both stacks initialize against the bucket and no `terraform.tfstate` remains in the working tree.

---

## Phase 2.5: Define backend, data and frontend specs: TODO
A design session with the user before any backend or frontend code. Output goes to `docs/` and the "Not yet defined" section of `AGENTS.md` is updated.

**D1** `docs/api-contract.md`: endpoints, request/response shapes, error format, auth behavior, upload flow, status values.
**D2** `docs/data-model.md`: tables (users/videos/quota reservations), indexes, state-machine columns, migrations approach.
**D3** `docs/frontend-spec.md`: pages, flows (login, upload, library, watch), component structure, how the app calls the API.
**D4** Decide build tool (Maven or Gradle), test tooling and package structure; record them in `AGENTS.md`.
*Done when:* the user approves D1 to D4 and `AGENTS.md` has real commands instead of "TBD".

---

## Phase 3: Backend (local first): TODO
**T3.1 Skeleton.** Spring Boot, Spring Security (resource server), Flyway migrations, PostgreSQL via Docker Compose, `server.servlet.context-path=/api`, actuator health only.
*Done when:* app starts locally and `/api/actuator/health` is UP.

**T3.2 JWT validation.** Signature (Google JWKS), issuer and audience for the Firebase project; user id = `sub`.
*Done when:* tests reject wrong `iss`, wrong `aud` and bad signature.

**T3.3 Data model and state machine.** Conditional-UPDATE transitions exactly as in section 6 of the architecture document.
*Done when:* tests cover duplicate messages, out-of-order messages, `COMPLETE` after `FAILED`, and no downgrade from `READY`.

**T3.4 Upload endpoint with quota.** Transactional quota check with row lock and byte reservation; presigned POST generation reusing the validated `PostSigner` approach from `spikes/spike2-java` (fixed key, `content-length-range`, content type, security token, short expiry); per-day upload limit.
*Done when:* tests show concurrent requests cannot exceed the quota and the reservation is released on `FAILED`.

**T3.5 Metadata endpoints.** Create/update title and description, list videos, get video with status and playback URL.
*Done when:* ownership is enforced by user id, with tests.

**T3.6 SQS consumer and cron.** `@SqsListener` using the message contract; unknown `videoId` acknowledged and discarded; `@Scheduled` job marks videos stuck over 2 hours as `FAILED` and releases reservations.
*Done when:* tests (LocalStack or equivalent) confirm idempotency and the conditional behavior.

**T3.7 Container image.** Dockerfile that includes `curl` for the ECS health check; 1 GB memory settings.
*Done when:* the image builds, runs locally and its health check passes.

---

## Phase 4: Infrastructure (`infra/main`): TODO
Build modules incrementally; the user applies and verifies each one.

**T4.1 Network.** VPC, 2 public subnets in 2 AZs, Internet Gateway, route tables.
**T4.2 Data.** RDS (not public, 2-AZ subnet group, SG only from the ECS SG, `skip_final_snapshot`, no deletion protection); generated password stored in SSM SecureString.
**T4.3 Compute.** ECR (lifecycle policy, `force_delete`), ECS cluster with `FARGATE_SPOT` associated through `aws_ecs_cluster_capacity_providers`, Spot-only service, **execution role** (ECR, logs, `ssm:GetParameters`) and **task role** (S3 `raw/*` PutObject, SQS receive/delete/get-attributes), container health check, deployment percentages 100/200, 7-day log retention.
**T4.4 Ingress.** Cloud Map private namespace with SRV service, VPC Link, HTTP API with routes `ANY /api/{proxy+}` and `ANY /api`, `HTTP_PROXY` integration to the Cloud Map service ARN.
**T4.5 Storage.** Three private buckets with Block Public Access and `force_destroy`; raw bucket CORS (`POST` from the site origin only) and 7-day lifecycle; processed bucket content under `videos/{videoId}/`.
**T4.6 CDN.** CloudFront with OAC, bucket policies granting `s3:GetObject` and `s3:ListBucket` to the distribution, the three behaviors, the Function on the default behavior only, `/api/*` managed policies, `/videos/*` CORS policy for dev origins, no global error responses.
*Done when (phase):* `tofu apply` works from the CI `infra` role with approval, and the deployed backend answers through CloudFront at `/api/...`.

---

## Phase 5: Transcoding pipeline: TODO
**T5.1 Lambda dispatcher.** Parse `videoId`, `CreateJob` with `ClientRequestToken = videoId` and `UserMetadata`, send `PROCESSING_STARTED`, failure destination with alarm, `iam:PassRole` limited to the MediaConvert role.
**T5.2 MediaConvert setup.** Role, job settings with few HLS renditions and a thumbnail, output to `videos/{videoId}/`.
**T5.3 SQS, DLQ and alarm.** Queue policy for `events.amazonaws.com` listing both rule ARNs, DLQ with redrive, CloudWatch alarm and SNS email.
**T5.4 EventBridge rules.** Two rules (`COMPLETE`, `ERROR`) on `aws.mediaconvert` with `userMetadata.videoId` present and input transformers producing the message contract.
*Done when:* a short real video ends `READY` with playable segments, a corrupt file ends `FAILED`, duplicated S3 events create only one job, and a message that exhausts its receives lands in the DLQ **and the alarm email arrives**.

---

## Phase 6: Frontend: TODO
Depends on `docs/frontend-spec.md` (D3).
**T6.1 Skeleton.** Next.js static export, `trailingSlash: true`, Tailwind, TypeScript.
**T6.2 Auth.** Firebase login and token attached to API calls.
**T6.3 Upload flow.** Request upload, POST to S3, show status updates.
**T6.4 Library and player.** Video list, metadata editing, `/watch/?v=<id>` with hls.js.
*Done when:* the full flow works in the browser through CloudFront: log in, upload, wait for `READY`, play.

---

## Phase 7: CI/CD and hardening: TODO
**T7.1 App deploy workflow.** Build and push image, update the ECS service, sync the frontend, invalidate CloudFront, using the `app-deploy` role.
**T7.2 Infra workflow.** Plan on pull request, apply after approval, using the `infra` role and environment.
**T7.3 Destroy test.** `tofu destroy` of `main` from a clean deployment.
*Done when:* destroy completes without manual cleanup and the bootstrap stack is intact; repeat after major infra changes.

**T7.4 Final acceptance checks.** Run the acceptance checks in the requirements document.
