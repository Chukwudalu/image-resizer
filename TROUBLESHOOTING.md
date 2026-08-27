# Troubleshooting Log

Commands used to debug real issues hit while building this project,
grouped by what problem they were solving. Kept as a reference for the
patterns, not just the specific commands — the general habit across all
of these: never trust "it should be working," check actual state at
each hop, and binary-search the pipeline when something's broken rather
than guessing which layer is at fault.

## 1. Terraform hang (SQS queue policy stuck "Still creating...")

| Command | Why | What we were looking for |
|---|---|---|
| `TF_LOG=DEBUG terraform apply` | Terraform's status ticker gave no real info — needed the actual HTTP request/response | The real AWS API error underneath the hang (found: `400 InvalidAttributeValue` from a lowercase `"version"` key in the policy JSON) |
| `aws sqs get-queue-attributes --attribute-names Policy RedrivePolicy` | Check whether the policy had actually landed on the queue, independent of what Terraform *thought* happened | Ground truth on the queue's real state |
| `timeout 15 aws sqs set-queue-attributes ...` | Ran the *exact same* API call directly via CLI, bypassing Terraform entirely | Isolate whether the problem was AWS-side (would hang here too) or Terraform-specific (would succeed instantly) — it succeeded, proving it was a config/data problem, not a hang |

## 2. State/reality mismatches

| Command | Why | What we were looking for |
|---|---|---|
| `terraform state list` | Checked repeatedly instead of trusting "I ran apply" | What Terraform actually has tracked, vs. what we assumed was applied |
| `terraform plan` (read before applying) | Sanity check before any `apply`/`destroy` | Confirming only the intended resources would change — catching surprises before they happen, not after |

## 3. Docker container issues

| Command | Why | What we were looking for |
|---|---|---|
| `docker ps -a --filter name=image-worker` | Container running detached, needed to check it hadn't silently died | Container status/uptime |
| `docker logs image-worker` | Expected print() output, got nothing | Whether the worker was actually processing — led to discovering the Python stdout-buffering issue (fixed with `PYTHONUNBUFFERED=1`) |
| `aws s3 ls .../processed/` (cross-checked against empty logs) | Logs showed nothing, but needed to know if work was *actually* happening anyway | Confirmed the pipeline worked despite silent logs — proved it was a logging visibility bug, not a processing failure |

## 4. ECR / image push issues

| Command | Why | What we were looking for |
|---|---|---|
| `aws ecr describe-images --repository-name image-pipeline-worker` | "Did we actually push?" kept coming up as an assumption | Ground truth: is there a real image in the registry, or is the repo empty |

## 5. ECS task crash-loop ("running: 0" mystery)

| Command | Why | What we were looking for |
|---|---|---|
| `aws ecs describe-services --query 'services[0].{status,desired,running}'` | First check when the pipeline stopped processing | Whether the service even had a live task |
| `aws ecs describe-services --query 'services[0].events[0:5]'` | `running: 0` alone doesn't say *why* | ECS's own diagnostic event log — this is what revealed `CannotPullContainerError: image ... not found` |
| `aws ecs list-tasks --desired-status STOPPED` + `aws ecs describe-tasks ... stoppedReason` | Backup plan in case the service events weren't specific enough | Per-task stop reason / exit code |
| `aws logs tail /ecs/image-pipeline-worker` | Needed the *application's* logs, not just ECS's infra-level status | Whether the worker code itself was erroring, vs. never even starting |

Root cause of this one: `terraform destroy` deletes the ECR repository
resource, which deletes every image inside it too (images aren't
Terraform state, they're pushed separately via `docker push`). A later
`terraform apply` recreates an empty repo with the same name/URL — it
doesn't restore old images. Fix each time this happens: re-run the
`docker login` / `tag` / `push` sequence, then force ECS to pick up the
now-real image:
```bash
aws ecs update-service --cluster image-pipeline-cluster \
  --service image-pipeline-worker-service \
  --force-new-deployment --region us-west-2
```

## 6. Custom CloudWatch metrics

| Command | Why | What we were looking for |
|---|---|---|
| `aws cloudwatch get-metric-statistics --namespace ImagePipeline --metric-name ImagesProcessed ...` | The IAM permission and code existing isn't proof it actually works | Real datapoints, confirming `PutMetricData` calls were succeeding end-to-end, not just present in the code |

## 7a. Security group replace deadlock (Phase 4, VPC migration)

Symptom: `aws_security_group.worker: Still destroying...` hung for 8+
minutes during the migration from the default VPC to the new one.

| Command | Why | What we were looking for |
|---|---|---|
| `aws ec2 describe-network-interfaces --filters "Name=group-id,Values=<sg-id>"` | A security group can only fail to delete for one reason: something still references it | Confirmed an ENI (`status: in-use`) was still attached — the delete wasn't hanging randomly, something concrete was blocking it |
| `aws ecs list-tasks` + `aws ecs describe-tasks ... --query '...createdAt,subnet...'` | Needed to know *what* owned that ENI | The running task's `createdAt` predated the apply, and its subnet was still the old default-VPC one — proved the ECS service migration had never actually started, not that it was slowly finishing |

Root cause: changing `vpc_id` forces Terraform to replace the security
group, and its default replacement order is **destroy old, then create
new**. But the *only* thing that would free up the old SG's ENI (the
ECS service redeploying into the new subnets) depends on the *new*
security group already existing — a genuine deadlock, not a slow
operation. Fix: add `lifecycle { create_before_destroy = true }` to the
security group so the new one is created first, letting the service
migrate (which drains the old task and releases its ENI) *before*
Terraform ever attempts to destroy the old security group.

General lesson: when a resource replacement hangs on destroy, ask "what
condition would make this specific delete fail?" and check that
directly, rather than waiting longer — a stuck delete almost always
means something still depends on it.

## 7. API Gateway / presigned URL chain

| Command | Why | What we were looking for |
|---|---|---|
| `curl -i "<api_url>?filename=..."` | Test the API layer in isolation before trusting the whole chain | Actual HTTP status + body — is the Lambda reachable and returning a valid presigned URL |
| `curl --upload-file fav.jpg "<presigned_url>"` | Test whether the presigned URL is actually usable, not just well-formed | Confirms a credential-less client can really upload |
| `aws s3 ls .../uploads/` then `.../processed/` | The full chain has several async hops (event -> queue -> worker) | Binary-search the pipeline — checking `uploads/` first told us the upload succeeded and the break was *downstream* of it, before checking anything ECS-related |

## General debugging toolkit (Linux-level, not project-specific)

Reference for local/system-level issues, not tied to a specific incident
above:

| Symptom | Commands |
|---|---|
| Something's hanging, no error | `ps aux \| grep <name>`, `lsof -p <PID>`, `strace -p <PID>` |
| Network connectivity | `ping <host>`, `curl -v <url>`, `ss -tnp`, `dig <host>` |
| Port already in use | `lsof -i :<port>`, `ss -ltnp \| grep <port>` |
| Which binary/venv is active | `which python`, `echo $PATH`, `python -c "import sys; print(sys.executable)"` |
| Permissions/ownership | `ls -la <file>`, `id`, `namei -l <path>` |
| Logs | `journalctl -u <service> -f`, `tail -f /var/log/syslog`, `dmesg -T \| tail -50` |

General habit: after anything fails, check `echo $?` for the exit code,
and reach for the tool's own verbose/debug flag before anything else
(`curl -v`, `TF_LOG=DEBUG`, `aws ... --debug`, `docker ... --log-level debug`).
