resource "aws_ecr_repository" "worker" {
    name = "image-pipeline-worker"
    image_tag_mutability = "IMMUTABLE"
    force_delete = true

    image_scanning_configuration {
        scan_on_push = true
    }
}