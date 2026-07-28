# 90-cloudwatch.tf
# Phase 7: application + node log group. (EKS control-plane logs go to their
# own group in 30-eks.tf.) Fluent Bit on every node ships pod + system logs here.

resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/eks/${var.name_prefix}/application"
  retention_in_days = 30

  tags = merge(local.common_tags, {
    Component = "fluent-bit"
  })
}
