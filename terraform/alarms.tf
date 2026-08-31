resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  alarm_name          = "image-pipeline-queue-depth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  threshold            = 10
  treat_missing_data    = "notBreaching"

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  period      = 60
  statistic   = "Average"

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }

  alarm_description = "Main queue backlog exceeds 10 messages for 3+ minutes"
}

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "image-pipeline-dlq-nonzero"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 1
  threshold            = 0
  treat_missing_data    = "notBreaching"

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  period      = 60
  statistic   = "Maximum"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_description = "Any message reached the DLQ - failed processing 3x, needs manual inspection"
}

resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "image-pipeline-error-rate-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 3
  threshold            = 0.05
  treat_missing_data    = "notBreaching"

  alarm_description = "Processing error rate exceeds 5% for 3+ minutes"

  metric_query {
    id          = "images_processed"
    return_data = false
    metric {
      namespace   = "ImagePipeline"
      metric_name = "ImagesProcessed"
      period      = 60
      stat        = "Sum"
      dimensions = {
        Service = "ImageProcessingService"
      }
    }
  }

  metric_query {
    id          = "processing_failures"
    return_data = false
    metric {
      namespace   = "ImagePipeline"
      metric_name = "ProcessingFailures"
      period      = 60
      stat        = "Sum"
      dimensions = {
        Service = "ImageProcessingService"
      }
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "processing_failures / (images_processed + processing_failures)"
    label       = "Error Rate"
    return_data = true
  }
}
