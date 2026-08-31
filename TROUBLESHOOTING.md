# Troubleshooting log

Notes from the actual debugging sessions while building this project. I'm keeping these mostly for myself, so future-me remembers the pattern and not just the one-off fix. If there's a theme across all of them it's this: don't trust that something "should" be working, go check the actual state of the thing, and when something's broken, narrow it down hop by hop instead of guessing which layer is at fault.

## 1. Terraform just hung on the SQS queue policy

First real scare of the project. `terraform apply` sat on `aws_sqs_queue_policy.main: Still creating...` for what felt like forever, no error, just a status ticker climbing past a minute, then two.

Turning on `TF_LOG=DEBUG` was what actually broke it open. Buried in the debug output was the real HTTP response Terraform was getting back from AWS: `400 InvalidAttributeValue`. The policy JSON I'd written had `version` lowercase instead of `Version`, which is one of those things that's completely invisible unless you're looking at the raw request.

The confusing part was why it looked like a hang instead of just failing fast. I ran the exact same `SetQueueAttributes` call directly with the CLI to see if it would hang too:

```bash
aws sqs set-queue-attributes --queue-url ... --attributes '{"Policy": "..."}'
```

It came back instantly, which told me the problem was in Terraform's handling of the bad response, not AWS being slow. Once I fixed the capitalization it applied normally.

## 2. Learning not to trust "I ran apply"

This isn't one incident so much as a habit I had to build. More than once I assumed something was applied because I'd typed the command, and it turned out either the apply had errored out partway or I'd run it in the wrong state. Now I just check:

```bash
terraform state list
```

before believing anything is actually live, and I read `terraform plan` output properly before hitting yes on an apply, instead of skimming it. Cheap insurance against surprises.

## 3. Worker container looked dead, wasn't

Ran the worker in Docker, uploaded a test image, and `docker logs` showed absolutely nothing. No "worker started," no processing output, nothing. My first assumption was that the container had crashed or wasn't picking up messages at all.

Checked `docker ps -a` first, container was still up. Then, mostly out of stubbornness, I checked S3 directly instead of trusting the logs:

```bash
aws s3 ls s3://jeremiah-image-pipeline/processed/
```

The resized files were there. It had worked the whole time. Turns out Python buffers stdout when it's not attached to a real terminal, so `print()` statements inside a detached container just sit in a buffer and never make it to `docker logs`. Fixed by adding `ENV PYTHONUNBUFFERED=1` to the Dockerfile. This one taught me to check the actual output of a system before trusting whatever logging mechanism I happened to be watching.

## 4. "Did I actually push the image?"

Small one, but I hit this enough times to write it down: after building and pushing a Docker image, before assuming it's in ECR, just check:

```bash
aws ecr describe-images --repository-name image-pipeline-worker
```

Cheaper than debugging a deploy that's using an image that was never actually there.

## 5. ECS service stuck at `running: 0`

The pipeline just stopped processing anything. `desiredCount` said 1, `runningCount` said 0. No obvious reason from that alone.

The service's own event log is what actually told me what was going on:

```bash
aws ecs describe-services --query 'services[0].events[0:5]'
```

`CannotPullContainerError: image ... not found`. Root cause: I'd run `terraform destroy` earlier and it takes the ECR repository down with it, images and all, since images aren't part of Terraform's state, they're pushed separately via `docker push`. When I ran `apply` again it recreated an empty repo with the same name, and I hadn't re-pushed anything into it. Fix was just re-running the login/tag/push sequence, then forcing ECS to actually try again:

```bash
aws ecs update-service --cluster image-pipeline-cluster \
  --service image-pipeline-worker-service \
  --force-new-deployment --region us-west-2
```

## 6. Confirming custom CloudWatch metrics actually work

The IAM permission being in place and the `put_metric_data` call being in the code doesn't mean it's actually landing anywhere. Checked with:

```bash
aws cloudwatch get-metric-statistics --namespace ImagePipeline --metric-name ImagesProcessed ...
```

Real datapoints showed up, so the whole chain (permission, code, delivery) was confirmed working end to end, not just present.

## 7. The security group that wouldn't die

This one took a while to actually understand, not just fix. Migrating the worker from the default VPC into the new one meant changing the security group's `vpc_id`, and Terraform sat on `aws_security_group.worker: Still destroying...` for eight minutes.

Checked what was actually keeping it alive:

```bash
aws ec2 describe-network-interfaces --filters "Name=group-id,Values=<sg-id>"
```

An ENI was still attached, `status: in-use`. So something was still using this security group. Next question was what:

```bash
aws ecs list-tasks
aws ecs describe-tasks --tasks <arn> --query '...createdAt,subnet...'
```

The running task's subnet was still the old default-VPC one, and its `createdAt` was from before this apply even started. That's when it clicked: the migration hadn't started at all. Terraform's default order for replacing a resource is delete the old one, then create the new one. But the only thing that could free up that ENI (the ECS service actually redeploying into the new subnet) needed the *new* security group to exist first. Chicken and egg. It wasn't slow, it was stuck.

Fix was adding a lifecycle block:

```hcl
lifecycle {
  create_before_destroy = true
}
```

which flips the order so the new one gets created first, the service can migrate onto it, and only then does the old one get torn down (by which point nothing's using it anymore).

Lesson I keep coming back to: when a delete hangs, ask what specific condition would make that delete fail, and go check for that condition directly instead of just waiting longer.

## 8. Testing the presigned URL flow

Standard sanity check I used a few times when wiring up the upload API. First hit the API directly to make sure the Lambda was even reachable:

```bash
curl -i "<api_url>?filename=test.jpg"
```

Then actually used the URL it gave back, since a well-formed-looking presigned URL isn't proof it works:

```bash
curl --upload-file fav.jpg "<presigned_url>"
```

Then checked `uploads/` and `processed/` in S3 in that order, since there are a few async hops in between (S3 event, SQS, the worker) and checking `uploads/` first tells you whether the problem is upstream or downstream of the actual upload.

## 9. The GitHub Actions OIDC error that made no sense

This one took the longest, and it's the one I'm proudest of actually solving properly instead of guessing my way through.

The workflow kept failing on `configure-aws-credentials` with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Same error, every retry, across hours, so it wasn't a fluke or a propagation delay.

Everything I checked externally looked correct:

- The actual deployed trust policy matched what I'd written in Terraform, checked with `aws iam get-role`
- GitHub's own API confirmed the repo name and casing matched exactly
- The OIDC provider (a shared one, reused from an older project) had `sts.amazonaws.com` in its client ID list, so the audience wasn't the problem

At that point I stopped trying to reason about what the token *should* contain and just had the workflow print what it actually was. Added a step that manually requests the OIDC token and decodes the JWT payload:

```bash
curl -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
  "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com"
```

then base64-decoded the middle segment to see the real claims. The actual `sub` was:

```
repo:Chukwudalu@28521165/image-resizer@1344565173:ref:refs/heads/main
```

Not the plain `repo:Chukwudalu/image-resizer:ref:refs/heads/main` my trust policy was checking for. Turns out GitHub permanently bakes a numeric account/repo ID into the token's subject claim once that account or repo has ever been renamed. It's a real security measure, it stops someone from renaming away from a username and having a new owner of that old name inherit trust from roles that still reference the plain name. But it means the friendly name you see everywhere (URLs, `git remote`) isn't what's actually in the token.

Fixed by updating the trust policy's `sub` condition to the real value. The lesson that stuck with me: when everything you can check indirectly says a config should be right, stop checking indirectly and go get the actual value at the source.

## 10. Load testing autoscaling, round one: nothing happened

Wanted to prove the backlog-per-task autoscaling policy actually worked, so I fired ~1000 synthetic messages at the queue and watched `desiredCount`/`runningCount`. Stayed at 1 the entire time.

First thing I checked was whether the load script had even sent anything:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name NumberOfMessagesSent ...
```

Zero. The script had some nested Python-inside-bash quoting that broke silently. Rewrote it more simply, ran it again, this time it genuinely sent messages, and the scaling *still* didn't trigger.

Checked queue depth over the window this time:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible --statistics Maximum ...
```

Basically flat. The messages were arriving in a slow trickle (sequential `send-message-batch` calls, one network round trip at a time) and the worker, for a tiny test image, was draining them just as fast. No backlog ever built up. Fixed the arrival side by sending in parallel instead of sequentially:

```bash
seq 1 100 | xargs -P 20 -I {} bash -c 'send_batch {}'
```

That finally created a real, if brief, spike (`Average: 52.0` visible messages for a moment). Still didn't trigger a scale-out though, and checking the alarm definitions explained why: the scale-out alarm needs 3 consecutive 1-minute breaching datapoints before it acts, and my burst drained faster than that. Not a bug, just not enough sustained load. The scale-*in* alarm (needs 15 minutes, deliberately much more patient) did visibly react to the spike, which was at least proof the whole alarm pipeline was alive and reading real data.

Takeaway: proving an autoscaler works needs load that's actually sustained relative to your system's real throughput, not just a big total number sent quickly.

## 11. That same load test quietly filled the dead letter queue

Found this because the DLQ alarm actually fired for real a bit later. 3001 messages sitting in the dead letter queue, way more than I'd even sent.

Peeked at one without deleting it:

```bash
aws sqs receive-message --queue-url <dlq-url> --max-number-of-messages 1 --attribute-names All
```

`ApproximateReceiveCount: 4`, so it had genuinely exhausted the retry policy, not some fluke. The DLQ tells you something failed but never why, so I went to the actual application logs:

```bash
aws logs filter-log-events --log-group-name /ecs/image-pipeline-worker --filter-pattern "Failed to process"
```

Mostly `403 Forbidden` on `HeadObject`, over and over. My first instinct was a permissions problem, but S3 actually returns 403 instead of 404 for a missing object when you only have scoped `GetObject` and no `ListBucket`, as a way of not leaking whether a key exists. So I just checked directly:

```bash
aws s3 ls s3://jeremiah-image-pipeline/uploads/fav.jpg
```

It didn't exist. The bucket had been destroyed and recreated earlier in the project (same incident as #5), and I'd re-uploaded `fav.jpg` plenty of times since then for various tests, but always under different filenames. Never back to the exact plain path my load test script had hardcoded. Every one of those synthetic messages failed for a completely legitimate reason and the DLQ did exactly what it was supposed to do.

Cleaned up with `aws sqs purge-queue` and re-uploaded the file before running anything again.

General playbook I'd use again for a DLQ: check the count and age, peek at a message without deleting it, go find the real exception in application logs, then cross-check what the message actually references against reality (does that object exist, does the role actually have the permission the error is complaining about), then decide whether to purge it or redrive it back for reprocessing.

## General Linux/debugging toolkit

Not specific to this project, just the stuff I reach for by default now:

| Symptom | Commands |
|---|---|
| Something's hanging, no error | `ps aux \| grep <name>`, `lsof -p <PID>`, `strace -p <PID>` |
| Network connectivity | `ping <host>`, `curl -v <url>`, `ss -tnp`, `dig <host>` |
| Port already in use | `lsof -i :<port>`, `ss -ltnp \| grep <port>` |
| Which binary/venv is active | `which python`, `echo $PATH`, `python -c "import sys; print(sys.executable)"` |
| Permissions/ownership | `ls -la <file>`, `id`, `namei -l <path>` |
| Logs | `journalctl -u <service> -f`, `tail -f /var/log/syslog`, `dmesg -T \| tail -50` |

And the habit underneath all of it: check `echo $?` after anything fails, and reach for the tool's own verbose flag before doing anything else (`curl -v`, `TF_LOG=DEBUG`, `aws ... --debug`).
