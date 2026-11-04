# AGENTS.md

Instructions for any AI coding agent working in this repository (Claude, Gemini, others).
Project: portfolio YouTube clone on AWS (event-driven, cost-optimized). Owner: Oliver.

## Source of truth
Read the relevant document **before** writing code or infrastructure, and consult it whenever a detail is unclear:

* `cloud_infrastructure_architecture_rev_4.md`: cloud design (network, compute, CDN, pipeline, IaC, CI/CD, costs).
* `project_context_and_requirements_rev_4.md`: functional and operational requirements.
* `implementation_plan.md`: ordered tasks with "Done when" criteria. Work on one task at a time, in order.

If something is undefined, ambiguous, or two documents conflict: **ask the user. Do not invent.**
If a design decision changes, update the affected document in the same change.

## Not yet defined (ask before assuming)
These are intentionally open. Do not make these decisions on your own:

* HTTP API contract (endpoints, request/response shapes, error format).
* Database schema details beyond what the requirements describe.
* Frontend pages, UX flows and component structure.
* Backend package structure and test tooling.

When these get defined, they will live in `docs/` and this section will be updated.

## Hard rules
* **Never run commands that create, change or delete AWS resources** (`tofu apply`, `tofu destroy`, `aws ... create/delete/put/update`, etc.). Only `tofu fmt`, `tofu validate` and `tofu plan` are allowed. Show the plan summary and let the user apply.
* **Never commit secrets**: no AWS keys, `.tfvars` with real values, `.env`, Firebase service accounts, state files. No static IAM keys anywhere; CI uses OIDC. Application secrets come from SSM Parameter Store.
* **Do not touch `infra/bootstrap` state or the state bucket** except through the planned bootstrap tasks.
* Do not add services, features or dependencies that are not described in the documents.
* Only claim that tests or commands passed if you ran them and saw the output. Report failures honestly.
* Keep changes small and focused on the current task.

## Working with several agents
* One task per agent. Work on a branch named `<agent>/<task-id>` (e.g. `claude/T1.1`, `gemini/T3.2`). Never commit directly to `main`.
* Do not edit files outside the scope of your task. If you need a change elsewhere, tell the user.
* Commit often with clear messages (English, imperative mood).
* Pull and rebase before starting a new task.

## Repository layout
```
infra/bootstrap/    state bucket, OIDC provider, CI roles, Budget (applied manually once, never destroyed with the app)
infra/main/         application infrastructure (the stack that `tofu destroy` removes)
backend/            Spring Boot
frontend/           Next.js static export
lambda/             S3-trigger dispatcher to MediaConvert
spikes/             validated experiments, reference only: do not modify
```

## Non-negotiable design constraints
Full rationale is in the architecture document. Violating these breaks the cost model or the security model:

* Public subnets only. **No NAT Gateway, no ALB.** Ingress is CloudFront → API Gateway HTTP API → VPC Link → Cloud Map (SRV) → Fargate.
* Fargate **Spot only**, single task. ECS security group accepts ingress only from the VPC Link security group.
* S3 buckets are private; CloudFront uses OAC. **No global CloudFront custom error responses.**
* Presigned **POST** (not PUT), signed manually with SigV4: fixed key, `content-length-range`, content type, `x-amz-security-token`, short expiry.
* SQS consumer is idempotent and applies monotonic state transitions. Unknown `videoId` is acknowledged and discarded.
* Two OpenTofu stacks (`bootstrap`, `main`). SSM Parameter Store, **not** Secrets Manager.
* Frontend routing uses `/watch/?v=<id>` (static export, `trailingSlash: true`).

## Stack (decided)
* Infra: OpenTofu 1.10+ (native S3 state locking), AWS provider ~> 5.0, region `us-east-1`.
* Backend: Java 17/21, Spring Boot, Spring Security (OAuth2 Resource Server), `io.awspring.cloud` for SQS, PostgreSQL.
* Frontend: Next.js, React, TypeScript, Tailwind CSS (static export).
* Auth: Firebase Authentication (JWT validated by the backend; no Admin SDK).
* CI/CD: GitHub Actions with AWS OIDC. Repository: `Oliveresm/youtube-clone`.

## Commands
* Infra (inside `infra/<stack>`): `tofu fmt -check`, `tofu validate`, `tofu plan`.
* Backend: TBD.
* Frontend: TBD.

## Language
* Reply to the user in **Spanish**.
* Code, comments, commit messages, and documentation in **English**.
