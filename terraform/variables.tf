variable "aws_region" {
    description = "The region aws resources will be located"
    default = "us-west-2"
    type = string
}

variable "bucket_name" {
    description = "Name of the S3 bucket for uploads and processed images"
    default     = "jeremiah-image-pipeline"
    type        = string
}