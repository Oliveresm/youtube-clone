# Implementation Plan: Cloud-Native YouTube Clone

This file only orders the work. Rules are in `AGENTS.md`, design in `cloud_infrastructure_architecture_rev_4.md` (arch), requirements in `project_context_and_requirements_rev_4.md`. A task is done only when its **Done when** criteria are verified with real command output.

## Completed work
* Repository, `.gitignore`, `AGENTS.md`, `CLAUDE.md` and the design documents are committed.
* Spikes 1 to 5 were run and destroyed; their findings are already merged into the architecture document. The code stays in `spikes/` as reference. One path was not verified: the CloudWatch alarm → SNS email (acceptance check 7).

---

## Phase 1: Bootstrap stack (applied manually, once): IN PROGRESS (T1.1 and T1.2 DONE; next T1.3)
Prerequisites (user): the email address for budget alerts.

**T1.1 State bucket: DONE.** In `infra/bootstrap`, manage the existing state bucket with the settings in arch §2, as the resource `aws_s3_bucket.state`, with `lifecycle { prevent_destroy = true }`. The bucket was created by hand, is empty, and is named `youtube-clone-<account-id>`: build the name from `aws_caller_identity` (no hardcoded account id). The user adopts it into the stack's state with `tofu import aws_s3_bucket.state <bucket-name>` before the plan; the agent does not run the import.
*Done when:* after the import, `tofu plan` shows only in-place updates or creations for versioning, Block Public Access, SSE-S3 and the TLS-only policy, and no destroy or replacement of the bucket.

**T1.2 AWS Budget: DONE.** The budget `youtube-clone-budget` ($30 monthly) already exists, created by hand in the console. Adopt it instead of creating another: manage it as `aws_budgets_budget.monthly` with the limit and notifications from arch §2. The user imports it first with `tofu import aws_budgets_budget.monthly <account-id>:youtube-clone-budget`; the agent does not run the import. The email is the variable `budget_email` (no default), set in a non-committed `terraform.tfvars`; provide `terraform.tfvars.example`.
*Done when:* after the import, `tofu plan` shows no destroy or replacement of the budget, and any in-place update only aligns it with arch §2 (three notifications, the user's email as subscriber).

**T1.3 GitHub OIDC provider and CI roles.** In `infra/bootstrap`, as decided in arch §7 (names, trust policies, permissions, boundary). The agent first proposes the design in Plan mode; the user reviews it before any code is written. The GitHub OIDC provider already exists in the account (`arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`; there can be only one per URL): adopt it as `aws_iam_openid_connect_provider.github` instead of creating it. The user imports it before the plan (`tofu import aws_iam_openid_connect_provider.github <arn>`); the agent does not run the import. Before that, the user checks its client IDs and which existing roles trust it, so adopting it cannot break anything else.
*Done when:* after the user applies, `aws iam get-role` shows both trust policies with the exact `aud` and `sub`, and the boundary is attached to `youtube-clone-infra`.

**T1.4 GitHub Environment and OIDC test.** The user creates the `infra` environment in GitHub with required reviewers. The agent adds a test workflow `.github/workflows/oidc-test.yml` that assumes `youtube-clone-app-deploy` from `main`, and `youtube-clone-infra` from the `infra` environment (after approval), and only prints `aws sts get-caller-identity`. Role ARNs are built from a repository variable for the account id (not hardcoded), and the job needs `permissions: id-token: write`.
*Done when:* both roles are assumed from the right context, the approval pause appears for `infra`, and assuming either role from another branch is denied.

**T1.5 Bootstrap state location.** Migrate the bootstrap state to the bucket (arch §7) with `tofu init -migrate-state`. The `main` stack is configured against the same bucket.
*Done when:* both stacks initialize against the bucket and no `terraform.tfstate` remains in the working tree.

---

## Phase 2: Define backend, data and frontend specs: TODO
A design session with the user before any backend or frontend code. Output goes to `docs/`, and the "Not yet defined" section of `AGENTS.md` is updated.

**D1** `docs/api-contract.md`: endpoints, request/response shapes, error format, auth behavior, upload flow, status values.
**D2** `docs/data-model.md`: tables (users/videos/quota reservations), indexes, state columns, migrations approach.
**D3** `docs/frontend-spec.md`: pages, flows (login, upload, library, watch), components, how the app calls the API.
**D4** Decide build tool (Maven or Gradle), test tooling and package structure; record them in `AGENTS.md`.
*Done when:* the user approves D1 to D4 and `AGENTS.md` has real commands instead of "TBD".

---

## Phase 3: Backend (local first): TODO
**T3.1 Skeleton.** Spring Boot, Spring Security, Flyway, PostgreSQL via Docker Compose, `server.servlet.context-path=/api`, actuator health only.
*Done when:* the app starts locally and `/api/actuator/health` is UP.

**T3.2 JWT validation** (arch §8).
*Done when:* tests reject wrong issuer, wrong audience and bad signature.

**T3.3 Data model and state machine** (arch §6).
*Done when:* tests cover duplicate messages, out-of-order messages, `COMPLETE` after `FAILED`, and no downgrade from `READY`.

**T3.4 Upload endpoint with quota** (requirements §3.2; presigned POST per arch §8, reusing the approach validated in `spikes/spike2-java`).
*Done when:* tests show concurrent requests cannot exceed the quota and the reservation is released on `FAILED`.

**T3.5 Metadata endpoints.** Create/update title and description, list videos, get video with status and playback URL.
*Done when:* ownership is enforced by user id, with tests.

**T3.6 SQS consumer and cron** (arch §5.2 steps 6 and 7).
*Done when:* tests (LocalStack or equivalent) confirm idempotency and the conditional behavior.

**T3.7 Container image** (arch §3 health check).
*Done when:* the image builds, runs locally and its health check passes.

---

## Phase 4: Infrastructure (`infra/main`): TODO
Build modules incrementally; the user applies and verifies each one. Details are in the architecture sections shown.

**T4.1 Network** (arch §3).
**T4.2 Data** (arch §3 database; generated password to SSM SecureString, arch §7).
**T4.3 Compute** (arch §3 and §8: ECR, cluster, Spot service, execution role and task role, health check, log retention).
**T4.4 Ingress** (arch §3: Cloud Map, VPC Link, HTTP API routes).
**T4.5 Storage** (arch §4: three buckets, raw CORS and lifecycle).
**T4.6 CDN** (arch §4: OAC, bucket policies, behaviors, Function).
**T4.7 Alerts** (arch §5.3: `alerts` SNS topic with `alert_email` variable).
*Done when (phase):* `tofu apply` works from the CI `infra` role with approval, and the deployed backend answers through CloudFront at `/api/...`.

---

## Phase 5: Transcoding pipeline: TODO
**T5.1 Lambda dispatcher** (arch §5.2 step 2).
**T5.2 MediaConvert setup** (arch §5.2 step 3).
**T5.3 SQS, DLQ and alarm** (arch §5.2 step 5, §5.3).
**T5.4 EventBridge rules** (arch §5.1 and §5.2 step 4).
*Done when:* a short real video ends `READY` with playable segments, a corrupt file ends `FAILED`, duplicated S3 events create only one job, and a message that exhausts its receives lands in the DLQ **and the alert email arrives**.

---

## Phase 6: Frontend: TODO
Depends on `docs/frontend-spec.md` (D3).
**T6.1 Skeleton.** Next.js static export, `trailingSlash: true`, Tailwind, TypeScript.
**T6.2 Auth.** Firebase login and token attached to API calls. (User: add the CloudFront domain to Firebase authorized domains.)
**T6.3 Upload flow.** Request upload, POST to S3, show status updates.
**T6.4 Library and player.** Video list, metadata editing, `/watch/?v=<id>` with hls.js.
*Done when:* the full flow works in the browser through CloudFront: log in, upload, wait for `READY`, play.

---

## Phase 7: CI/CD and hardening: TODO
**T7.1 App deploy workflow** (build and push image, update ECS service, sync frontend, invalidate CloudFront; `app-deploy` role).
**T7.2 Infra workflow** (plan on pull request, apply after approval; `infra` role and environment).
**T7.3 Destroy test.** `tofu destroy` of `main` from a clean deployment.
*Done when:* destroy completes without manual cleanup and the bootstrap stack is intact; repeat after major infra changes.

**T7.4 Final acceptance checks.** Run the acceptance checks in the requirements document.
