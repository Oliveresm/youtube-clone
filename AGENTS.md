# AGENTS.md

Instructions for any AI coding agent working in this repository (Claude, Gemini, others).
Project: portfolio YouTube clone on AWS (event-driven, cost-optimized). Owner: Oliver.

## Source of truth
Each fact lives in exactly one file. Read the relevant one **before** writing code or infrastructure, and consult it whenever a detail is unclear:

* `cloud_infrastructure_architecture_rev_4.md`: **how** it is built on AWS (resources, policies, roles, pipeline, IaC, CI/CD, costs). Wins over other documents on conflicts.
* `project_context_and_requirements_rev_4.md`: **what** the system must do, and the acceptance checks. Refers to the architecture by section.
* `implementation_plan.md`: the **order** of the work, one task at a time, each with "Done when" criteria.

If something is undefined, ambiguous, or two documents conflict: **ask the user. Do not invent.**
If a design decision changes, update the one file that owns it in the same change.

## Not yet defined (ask before assuming)
These are intentionally open. Do not make these decisions on your own:

* HTTP API contract (endpoints, request/response shapes, error format).
* Database schema details beyond what the requirements describe.
* Frontend pages, UX flows and component structure.
* Backend build tool, package structure and test tooling.

When these get defined they will live in `docs/` and this section will be updated.

## Hard rules
* **Never run commands that create, change or delete AWS resources** (`tofu apply`, `tofu destroy`, `aws ... create/delete/put/update`, etc.). Allowed: `tofu init`, `tofu fmt`, `tofu validate`, `tofu plan`, and read-only AWS CLI commands (`describe`/`list`/`get`, `sts get-caller-identity`). Show the plan summary and let the user apply. **No exceptions**: not even if the user asks in chat or it seems necessary to finish the task. If an apply, import or destroy is needed, stop and give the user the exact command to run themselves.
* **Never commit secrets**: no AWS keys, `.tfvars` with real values, `.env`, Firebase service accounts, state files. No static IAM keys anywhere. Provide `*.tfvars.example` files without real values.
* Do not touch the state bucket or any state file except through the planned bootstrap tasks.
* Do not add services, features or dependencies that are not described in the documents.
* Only claim that tests or commands passed if you ran them and saw the output. Report failures honestly.
* Keep changes small and focused on the current task.

## Working with several agents
* One task per agent. Work on a branch named `<agent>/<task-id>` (e.g. `claude/T1.1`, `gemini/T3.2`). Never commit directly to `main`.
* Do not edit files outside the scope of your task. If you need a change elsewhere, tell the user.
* Commit often with clear messages (English, imperative mood). Pull and rebase before starting a new task.

## Repository layout
```
infra/bootstrap/    state bucket, OIDC provider, CI roles, Budget (applied manually once, never destroyed with the app)
infra/main/         application infrastructure (the stack that `tofu destroy` removes)
backend/            Spring Boot
frontend/           Next.js static export
lambda/             S3-trigger dispatcher to MediaConvert
docs/               specs defined later (API contract, data model, frontend)
spikes/             validated experiments, reference only: do not modify
```

## Critical constraints
The architecture document has the full list and rationale. The ones that most often get "improved" by mistake:

* Public subnets only. **No NAT Gateway, no ALB.**
* Fargate **Spot only**, single task.
* **Presigned POST** (not PUT), signed manually with SigV4.
* SSM Parameter Store, **not** Secrets Manager.
* **No global CloudFront custom error responses.**

## Stack, commands and language
* Stack: see `project_context_and_requirements_rev_4.md` section 2. AWS provider `~> 5.0`, region `us-east-1`. Repository and CI identity: architecture section 7.
* Infra commands (inside `infra/<stack>`): `tofu init`, `tofu fmt -check`, `tofu validate`, `tofu plan`.
* Backend and frontend commands: TBD.
* Reply to the user in **Spanish**. Code, comments, commit messages and documentation in **English**.
