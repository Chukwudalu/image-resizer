# data "aws_vpc" "default" {
#     default = true
# }

# data "aws_subnets" "default" {
#     filter {
#       name = "vpc-id"
#       values = [data.aws_vpc.default.id]
#     }
# }

resource "aws_security_group" "worker" {
    name = "image-pipeline-worker-sg"
    description = "Outbound only - worker has no inbound listener"
    vpc_id = aws_vpc.main.id

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    lifecycle {
      create_before_destroy = true
    }
}