resource "aws_iam_role" "upload_lambda" {
    name = "image-pipeline-upload-lamda-role"

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = {Service = "lambda.amazonaws.com"}
            Action = "sts:AssumeRole"
        }]
    })
}


resource "aws_iam_role_policy_attachment" "upload_lambda_logs" {
    role =  aws_iam_role.upload_lambda.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "upload_lambda_s3" {
    name = "upload-lambda-s3-policy"
    role = aws_iam_role.upload_lambda.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Action = ["s3:PutObject"]
            Resource = "${aws_s3_bucket.image_pipeline.arn}/uploads/*"
        }]
    })
}

data "archive_file" "upload_lambda" {
  type        = "zip"
  source_file = "${path.module}/../upload_handler.py"
  output_path = "${path.module}/upload_handler.zip"
}

resource "aws_lambda_function" "upload" {
  function_name    = "image-pipeline-upload-handler"
  filename         = data.archive_file.upload_lambda.output_path
  source_code_hash = data.archive_file.upload_lambda.output_base64sha256
  handler          = "upload_handler.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.upload_lambda.arn
  timeout          = 10
}
