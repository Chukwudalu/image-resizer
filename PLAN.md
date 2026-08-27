# Cloud Image Processing Pipeline — Project Plan

## What this is

A user uploads an image via a presigned URL, and the system asynchronously
produces `thumbnail.jpg` (150x150), `medium.jpg` (800x800), and
`large.jpg` (1600x1600), storing the results back in S3.

The point of the project is to learn cloud/DevOps concepts by building the
real thing in layers — not to copy a finished Terraform stack. Each phase
below should be independently working and demoable before moving to the
next.

Architecturally this is two microservices, independently deployable and
IAM-scoped: the **upload service** (Lambda + API Gateway, Phase 3) and
the **image processing service** (the ECS/Fargate worker, Phase 2).

## Requirements

- **Upload**: client requests a presigned URL from an API, uploads directly
  to S3 (no credentials on the client).
- **Processing**: async, decoupled from upload — S3 event -> SQS -> worker.
- **Failure handling**: retry with backoff, poison messages go to a DLQ
  for inspection rather than being silently dropped or retried forever.
- **Output access**: resized images need to be fetchable after processing
  (mechanism — presigned GET vs. public/CloudFront — decided in Phase 3).
- **Deployment posture**: full 2-AZ architecture while learning, torn down
  between sessions to control cost; a separate cheap always-on "showcase"
  deployment added later for the job-search period.

## Key architecture decisions

| Decision | Choice | Why |
|---|---|---|
| Upload API compute | **Lambda + API Gateway**, not ECS | Stateless, low-traffic, bursty — paying for an idle 24/7 Fargate service + ALB to hand back signed URLs doesn't buy anything. Mixing serverless (thin glue) with containers (the actual work) is itself a realistic pattern worth being able to explain. |
| Resize worker compute | **ECS/Fargate** | Long-running, needs control over runtime/resources (Pillow, memory for large images) — the actual point of the ECS/VPC learning goals. |
| Queueing | **SQS with redrive policy -> DLQ** | Decouples upload from processing, absorbs bursts, gives natural backpressure for autoscaling. Retry + DLQ is the realistic failure-handling pattern vs. log-and-drop. |
| Networking | **Full VPC, 2 AZs, public/private subnets, NAT, ALB** (Phase 4+) | The explicit learning goal. Skipped in early phases (default VPC) to avoid blocking on networking before the app logic works. |
| IaC | **Terraform**, applied after resources are understood manually first | Avoid learning Terraform syntax and the AWS concept at the same time. |
| Cost control | **Destroy between sessions** (`terraform destroy`) during Phases 1-7 | NAT Gateway (~$65/mo) and ALB (~$18/mo) bill hourly regardless of use; full 2-AZ stack left running 24/7 is ~$120-150/mo. Torn down between sessions, actual cost is low single digits/month. |
| Showcase deployment (Phase 8) | Single-AZ, no NAT (public-subnet tasks or S3 gateway endpoint), smallest Fargate size | ~$15-25/mo always-on, acceptable for a job-search window; kept as a separate, smaller deployment rather than running the full learning stack continuously. |

## Milestones

### Phase 0 — Local resize logic
Pillow script producing the three output sizes from a local input file.
**Acceptance:** `python resize.py image.jpg` produces correctly sized
`_thumbnail`, `_medium`, `_large` outputs.

### Phase 1 — AWS primitives, no orchestration [DONE 2026-08-17]
S3 bucket (uploads + processed), SQS queue + DLQ, IAM roles — built with
Terraform (see 2026-08-15 decision log entry). A local Python script
polls SQS and does the resize work, standing in for the future ECS
worker.
**Acceptance:** upload a file to S3 -> event fires -> SQS message ->
local script picks it up, resizes, uploads results back to S3.

### Phase 2 — Containerize + ECS worker [DONE 2026-08-20]
Dockerize the worker from Phase 1, push to ECR, run as an ECS Fargate
service/task. Replace the Phase 1 `image-pipeline-worker` IAM user
(static access keys, a local-dev-only stand-in) with an ECS task role —
the container gets short-lived credentials automatically via the ECS
agent, nothing to leak or rotate. Delete the IAM user's access key once
the task role is confirmed working. Worker emits custom CloudWatch
metrics (`ImagesProcessed`, `ProcessingFailures`, `ProcessingTime`) —
see 2026-08-17 decision log entry.
**Acceptance:** worker runs in Fargate (not your laptop) and still
processes real messages end-to-end, with zero static AWS credentials in
the container/image/environment, emitting metrics to CloudWatch.

### Phase 3 — Upload API [DONE 2026-08-21]
Lambda behind API Gateway, issuing presigned S3 PUT URLs, IAM-scoped to
the uploads bucket/prefix. Output access mechanism (presigned GET vs.
public) deferred to Phase 9 — decided by what the frontend actually
needs, not independently.
**Acceptance:** upload via `curl`/Postman using only a presigned URL, no
AWS credentials on the client.

### Phase 4 — Full VPC networking [DONE 2026-08-23]
VPC, public/private subnets across 2 AZs, NAT (one per AZ), route
tables, security groups. No ALB — see 2026-08-22 decision log entry.
The ECS worker moves into private subnets (no public IP), reaching
ECR/S3/SQS/CloudWatch via NAT instead. The Lambda upload API stays
outside the VPC entirely (it only calls public AWS service endpoints,
not private VPC resources — putting it in a VPC would add cold-start
latency and its own NAT dependency for no benefit).
**Acceptance:** everything from Phases 1-3 still works, now properly
network-isolated; worker has no public IP.

### Phase 5 — Infrastructure as Code [DONE 2026-08-24]
Since Terraform is now used from Phase 1 onward, this phase is about
consolidating/cleaning up the accumulated `.tf` files rather than a
from-scratch rewrite. Extracted `bucket_name` and the last hardcoded
`aws_region` literal into variables (`terraform plan` showed zero
changes, confirming it was a pure refactor). Modules skipped — not
warranted with a single deployment; revisit if/when Phase 8's showcase
deployment needs to reuse this config for a second, separate stack.
SQS naming inconsistency (`image-processing-*` vs `image-pipeline-*`
everywhere else) deliberately left as-is — cosmetic only, and fixing it
forces both queues to be recreated for no functional benefit; revisit
only if it becomes actually confusing.
**Acceptance:** `terraform destroy && terraform apply` reproduces the
whole stack from zero.

### Phase 6 — CI/CD
GitHub Actions: test -> build -> push to ECR -> deploy to ECS on merge.
**Acceptance:** a worker code change reaches Fargate without touching the
AWS console.

### Phase 7 — Observability + autoscaling
CloudWatch dashboards/alarms built on the metrics already emitted since
Phase 2 (`ImagesProcessed`, `ProcessingFailures`, `ProcessingTime`) plus
SQS's built-in metrics (messages available/in-flight, DLQ depth). Alarms
for queue depth > threshold, DLQ messages > 0, and error rate > 5%
(computed via metric math, not a directly-emitted metric). ECS worker
autoscaling on SQS queue depth.
**Acceptance:** pushing ~1000 test messages onto the queue visibly scales
worker count up, then back down once drained; alarms fire correctly when
tested (e.g. deliberately pushing a corrupt file into the DLQ).

## Known gaps

Things we've deliberately deferred rather than fixed on the spot — noted
here so they don't get forgotten before the phase that should address
them:

- ~~**`worker.py` doesn't handle `SIGTERM`.**~~ **RESOLVED 2026-08-24.**
  Added a `signal.signal(SIGTERM, handle_sigterm)` handler in `main()`
  using `nonlocal running` (first attempt used `global`, which silently
  didn't work — `running` was a local var in `main()`, not module-level,
  so the handler was mutating an unrelated global that the loop never
  read). Verified for real against the deployed ECS task, not just
  locally: `aws ecs stop-task` to send a genuine `SIGTERM`, confirmed
  both the "SIGTERM received..." and "Worker exiting cleanly." log lines
  appeared and the container's exit code was `0` (clean exit, not
  `SIGKILL`ed). See `TROUBLESHOOTING.md` for the local-Docker-testing
  wrinkle this surfaced (Phase 1's IAM user was already retired per
  Phase 2's own plan, so local `docker run` testing needed a different
  path — tested directly against ECS instead, which is arguably the more
  representative test surface anyway since that's where SIGTERM is
  actually sent in real operation).

### Phase 8 — Showcase deployment
Trimmed always-on variant (single AZ, no NAT, smallest task size) for the
job-search period, deployed separately from the learning stack. Recorded
demo/README for when live isn't feasible.
**Acceptance:** deployed independently of the Phase 0-7 stack, stays
within the ~$15-25/mo budget.

### Phase 9 — Frontend
A simple web UI: upload a file (calls the Phase 3 upload API, then PUTs
directly to the presigned URL), and view/download the resulting
thumbnail/medium/large versions. Determines the final output-access
mechanism left open in Phase 3 (presigned GET vs. public/CloudFront) —
decided by what the frontend actually needs, not independently of it.
Added to the plan 2026-08-20; CORS support was added to the upload
Lambda in Phase 3 in anticipation of this rather than retrofitted later.
**Acceptance:** a real browser session can upload an image and see all
three resized versions without touching the AWS console or CLI.

## Open decisions log

Decisions we've deliberately made and why, kept here so we don't
re-litigate them later without a reason:

- **2026-08-14**: Upload API is Lambda, not ECS, despite the original
  diagram showing ECS — see architecture decisions table above.
- **2026-08-14**: Full 2-AZ architecture built for learning, destroyed
  between sessions; NOT left running as the job-search demo. A separate
  Phase 8 showcase deployment handles that instead.
- **2026-08-15**: Switched to Terraform starting Phase 1, rather than
  CLI-first through Phase 4 as originally planned. Original reasoning
  (isolate AWS-concept errors from Terraform/HCL errors while new to
  both) still applies as a risk to watch for, but user chose to proceed
  with Terraform now.
- **2026-08-22**: Dropped the ALB from Phase 4. It only ever existed in
  the original diagram to front "ECS API" — once Phase 3 made the
  upload API Lambda + API Gateway instead of ECS, there was nothing left
  for an ALB to legitimately front (API Gateway already is the public
  entry point for Lambda; the worker has no inbound traffic, ever).
  Building an ALB with no real target group would be infra for its own
  sake, not a real architecture decision.
- **2026-08-17**: Custom CloudWatch metrics (`ImagesProcessed`,
  `ProcessingFailures`, `ProcessingTime`) are instrumented directly in
  `worker.py` as part of Phase 2, rather than bolted on in Phase 7.
  Reasoning: cheap to add while already writing the service, natural to
  write alongside the logic. Alarms/dashboards built on top of these
  metrics remain in Phase 7 as originally planned — that's genuinely
  separate infra work.

## Working agreement

- Code/commands are given in chat for the user to type and run themselves
  (learning mode) — not written directly to files — until they say
  otherwise for this project.
- Claims about behavior get verified by actually running things, not by
  reading/reasoning about code alone.
