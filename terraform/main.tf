resource "aws_s3_bucket" "image_pipeline" {
    bucket = var.bucket_name
    force_destroy = true
}

resource "aws_sqs_queue" "dlq" {
    name = "image-processing-dlq"
}

resource "aws_sqs_queue" "main" {
    name = "image-processing-queue"

    redrive_policy = jsonencode({
        deadLetterTargetArn = aws_sqs_queue.dlq.arn
        maxReceiveCount = 3
    })
}

resource "aws_sqs_queue_policy" "main" {
    queue_url = aws_sqs_queue.main.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect    = "Allow"
            Principal = { Service = "s3.amazonaws.com" }
            Action    = "sqs:SendMessage"
            Resource  = aws_sqs_queue.main.arn
            Condition = {
                ArnLike = {
                    "aws:SourceArn" = aws_s3_bucket.image_pipeline.arn
                }
            } 
        }]
    })
}

resource "aws_s3_bucket_notification" "uploads" {
    bucket = aws_s3_bucket.image_pipeline.id

    queue {
        queue_arn = aws_sqs_queue.main.arn
        events = ["s3:ObjectCreated:*"]
        filter_prefix = "uploads/"
    }

    depends_on = [ aws_sqs_queue_policy.main ]
}
