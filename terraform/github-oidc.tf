data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}


resource "aws_iam_role" "github_actions" {
    name = "image-pipeline-github-actions-role"
    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn}
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {
                StringEquals = {
                    "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
                }
                StringLike = { 
                "token.actions.githubusercontent.com:sub" = "repo:Chukwudalu/image-resizer:ref:refs/heads/main"
                }
            }
        }]
    })
}


resource "aws_iam_role_policy" "github_actions" {
    name = "image-pipeline-github-actions-policy"
    role = aws_iam_role.github_actions.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            {
                Effect = "Allow"
                Action = ["ecr:GetAuthorizationToken"]
                Resource = "*"
            },
            {
                Effect = "Allow"
                Action = [
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:BatchGetImage",
                "ecr:PutImage",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload"
                ]
                Resource = aws_ecr_repository.worker.arn
            },
            {
                Effect = "Allow"
                Action = [
                "ecs:RegisterTaskDefinition",
                "ecs:DescribeTaskDefinition"
                ]
                Resource = "*"
            },
            {
                Effect = "Allow"
                Action = [
                "ecs:UpdateService",
                "ecs:DescribeServices"
                ]
                Resource = aws_ecs_service.worker.id
            },
            {
                Effect   = "Allow"
                Action   = ["iam:PassRole"]
                Resource= [aws_iam_role.execution.arn, aws_iam_role.task.arn]
            }
        ]
    })
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}