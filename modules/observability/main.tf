# observability: what tells you the stack is healthy, and tells you first when it is not.
#
#   - SNS alerts topic (+ optional email subscription)
#   - alarms: each app has < 1 running task; EFS burst credits low; EFS lost all clients;
#             NAT port-allocation errors; AWS Backup job failed; app log errors;
#             reader ever logged WRITE_PROBE ALLOWED (the read-only control is broken)
#   - log metric filters that feed the last two
#   - a CloudWatch dashboard (apps, EFS, NAT, log error counts)
#   - optional: activate the `Project` cost allocation tag for Cost Explorer grouping
#
# Container Insights (RunningTaskCount etc.) is switched on in modules/apps on the cluster.

locals {
  services = {
    writer = var.writer_service_name
    reader = var.reader_service_name
  }
  ns = "${var.name}/apps" # custom namespace for log-derived metrics
}

# ---------------------------------------------------------------- alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------- log-derived metrics
resource "aws_cloudwatch_log_metric_filter" "writer_errors" {
  name           = "${var.name}-writer-errors"
  log_group_name = var.writer_log_group
  pattern        = "WRITE_ERROR"

  metric_transformation {
    name          = "WriterErrors"
    namespace     = local.ns
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "reader_errors" {
  name           = "${var.name}-reader-errors"
  log_group_name = var.reader_log_group
  pattern        = "?READ_ERROR ?LIST_ERROR"

  metric_transformation {
    name          = "ReaderErrors"
    namespace     = local.ns
    value         = "1"
    default_value = "0"
  }
}

# If this ever counts, the read-only control (R3) is not holding. Alarm immediately.
resource "aws_cloudwatch_log_metric_filter" "reader_write_allowed" {
  name           = "${var.name}-reader-write-allowed"
  log_group_name = var.reader_log_group
  pattern        = "\"WRITE_PROBE ALLOWED\""

  metric_transformation {
    name          = "ReaderWriteAllowed"
    namespace     = local.ns
    value         = "1"
    default_value = "0"
  }
}

# ---------------------------------------------------------------- alarms
resource "aws_cloudwatch_metric_alarm" "service_down" {
  for_each = local.services

  alarm_name          = "${var.name}-${each.key}-no-running-task"
  alarm_description   = "${each.key} service has no running task (R2/R3 apps are down)."
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = each.value }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no metric at all means no task either
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "efs_burst_credits_low" {
  alarm_name          = "${var.name}-efs-burst-credits-low"
  alarm_description   = "EFS burst credit balance is below the floor; throughput will throttle (bursting mode, R12)."
  namespace           = "AWS/EFS"
  metric_name         = "BurstCreditBalance"
  dimensions          = { FileSystemId = var.file_system_id }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.efs_burst_credit_floor_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "efs_no_clients" {
  alarm_name          = "${var.name}-efs-no-clients"
  alarm_description   = "No client is connected to the EFS for 15 minutes (both apps lost the mount?)."
  namespace           = "AWS/EFS"
  metric_name         = "ClientConnections"
  dimensions          = { FileSystemId = var.file_system_id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "nat_port_errors" {
  for_each = toset(var.nat_gateway_ids)

  alarm_name          = "${var.name}-nat-${each.value}-port-allocation-errors"
  alarm_description   = "NAT gateway ${each.value} failed to allocate a source port (connection errors for the apps)."
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  dimensions          = { NatGatewayId = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "backup_failed" {
  alarm_name          = "${var.name}-backup-job-failed"
  alarm_description   = "An AWS Backup job for the EFS failed (R14)."
  namespace           = "AWS/Backup"
  metric_name         = "NumberOfBackupJobsFailed"
  dimensions          = { BackupVaultName = var.backup_vault_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "app_log_errors" {
  for_each = {
    writer = aws_cloudwatch_log_metric_filter.writer_errors.metric_transformation[0].name
    reader = aws_cloudwatch_log_metric_filter.reader_errors.metric_transformation[0].name
  }

  alarm_name          = "${var.name}-${each.key}-log-errors"
  alarm_description   = "${each.key} logged an error line in the last 5 minutes."
  namespace           = local.ns
  metric_name         = each.value
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "reader_write_allowed" {
  alarm_name          = "${var.name}-reader-write-allowed"
  alarm_description   = "SECURITY: the reader was able to write (R3 control broken). Investigate the EFS file-system policy."
  namespace           = local.ns
  metric_name         = aws_cloudwatch_log_metric_filter.reader_write_allowed.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------- dashboard
locals {
  w = { type = "metric", width = 12, height = 6 }
  dashboard = {
    widgets = [
      merge(local.w, { x = 0, y = 0, properties = { title = "Running tasks", region = var.region, stat = "Minimum", period = 60, metrics = [
        for k, s in local.services : ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", s, { label = k }]
      ] } }),
      merge(local.w, { x = 12, y = 0, properties = { title = "CPU / memory (%)", region = var.region, stat = "Average", period = 60, metrics = flatten([
        for k, s in local.services : [
          ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", s, { label = "${k} cpu" }],
          ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", s, { label = "${k} mem" }],
        ]
      ]) } }),
      merge(local.w, { x = 0, y = 6, properties = { title = "EFS I/O bytes", region = var.region, stat = "Sum", period = 300, metrics = [
        ["AWS/EFS", "DataWriteIOBytes", "FileSystemId", var.file_system_id, { label = "write" }],
        ["AWS/EFS", "DataReadIOBytes", "FileSystemId", var.file_system_id, { label = "read" }],
        ["AWS/EFS", "MetadataIOBytes", "FileSystemId", var.file_system_id, { label = "metadata" }],
      ] } }),
      merge(local.w, { x = 12, y = 6, properties = { title = "EFS burst credits / clients", region = var.region, stat = "Minimum", period = 300, metrics = [
        ["AWS/EFS", "BurstCreditBalance", "FileSystemId", var.file_system_id, { label = "burst credits (bytes)" }],
        ["AWS/EFS", "ClientConnections", "FileSystemId", var.file_system_id, { label = "clients", yAxis = "right", stat = "Sum" }],
      ] } }),
      merge(local.w, { x = 0, y = 12, properties = { title = "NAT bytes out / port errors", region = var.region, stat = "Sum", period = 300, metrics = flatten([
        for n in var.nat_gateway_ids : [
          ["AWS/NATGateway", "BytesOutToDestination", "NatGatewayId", n, { label = "${n} bytes out" }],
          ["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", n, { label = "${n} port errors", yAxis = "right" }],
        ]
      ]) } }),
      merge(local.w, { x = 12, y = 12, properties = { title = "App log errors (count)", region = var.region, stat = "Sum", period = 300, metrics = [
        [local.ns, "WriterErrors", { label = "writer" }],
        [local.ns, "ReaderErrors", { label = "reader" }],
        [local.ns, "ReaderWriteAllowed", { label = "READER WROTE (must stay 0)", color = "#d62728" }],
      ] } }),
    ]
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name}-overview"
  dashboard_body = jsonencode(local.dashboard)
}

# ---------------------------------------------------------------- cost allocation tag (opt-in)
resource "aws_ce_cost_allocation_tag" "project" {
  count = var.activate_cost_allocation_tag ? 1 : 0

  tag_key = "Project"
  status  = "Active"
}
