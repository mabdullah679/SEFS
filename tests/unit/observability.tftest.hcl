# modules/observability: alarms wired to the alerts topic, log-derived metrics, dashboard.

mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:ap-southeast-2:111122223333:sefs-ut-alerts"
    }
  }
}

variables {
  name                = "sefs-ut"
  region              = "ap-southeast-2"
  cluster_name        = "sefs-ut"
  writer_service_name = "sefs-ut-writer"
  reader_service_name = "sefs-ut-reader"
  file_system_id      = "fs-0123456789abcdef0"
  nat_gateways_by_az  = { "ap-southeast-2a" = "nat-0aaaaaaaaaaaaaaaa", "ap-southeast-2b" = "nat-0bbbbbbbbbbbbbbbb" }
  writer_log_group    = "/ecs/sefs-ut/writer"
  reader_log_group    = "/ecs/sefs-ut/reader"
  backup_vault_name   = "sefs-ut"
}

run "every_alarm_notifies_the_alerts_topic" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition = alltrue(concat(
      [for a in aws_cloudwatch_metric_alarm.service_down : contains(a.alarm_actions, aws_sns_topic.alerts.arn)],
      [for a in aws_cloudwatch_metric_alarm.nat_port_errors : contains(a.alarm_actions, aws_sns_topic.alerts.arn)],
      [for a in aws_cloudwatch_metric_alarm.app_log_errors : contains(a.alarm_actions, aws_sns_topic.alerts.arn)],
      [
        contains(aws_cloudwatch_metric_alarm.efs_burst_credits_low.alarm_actions, aws_sns_topic.alerts.arn),
        contains(aws_cloudwatch_metric_alarm.efs_no_clients.alarm_actions, aws_sns_topic.alerts.arn),
        contains(aws_cloudwatch_metric_alarm.backup_failed.alarm_actions, aws_sns_topic.alerts.arn),
        contains(aws_cloudwatch_metric_alarm.reader_write_allowed.alarm_actions, aws_sns_topic.alerts.arn),
      ]
    ))
    error_message = "Every alarm must notify the alerts topic; a silent alarm is not an alarm."
  }
  assert {
    condition     = length(output.alarm_names) == 2 + 2 + 2 + 4
    error_message = "Expected 10 alarms: 2 service-down, 2 NAT, 2 app-log, EFS credits, EFS clients, backup, reader-write-allowed."
  }
}

run "service_down_alarm_treats_missing_as_breaching" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition = alltrue([
      for a in aws_cloudwatch_metric_alarm.service_down :
      a.namespace == "ECS/ContainerInsights" && a.metric_name == "RunningTaskCount" && a.threshold == 1 &&
      a.comparison_operator == "LessThanThreshold" && a.treat_missing_data == "breaching" &&
      a.dimensions["ClusterName"] == "sefs-ut"
    ])
    error_message = "Service-down alarms must watch RunningTaskCount < 1 on the cluster and treat a missing metric as DOWN (no metric = no task)."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.service_down["reader"].dimensions["ServiceName"] == "sefs-ut-reader" && aws_cloudwatch_metric_alarm.service_down["writer"].dimensions["ServiceName"] == "sefs-ut-writer"
    error_message = "Each service-down alarm must point at its own service."
  }
}

run "reader_write_allowed_is_a_security_alarm" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.reader_write_allowed.pattern == "\"WRITE_PROBE ALLOWED\"" && aws_cloudwatch_log_metric_filter.reader_write_allowed.log_group_name == "/ecs/sefs-ut/reader"
    error_message = "The reader log group must be filtered for the exact WRITE_PROBE ALLOWED line (R3 control broken)."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.reader_write_allowed.threshold == 0 && aws_cloudwatch_metric_alarm.reader_write_allowed.comparison_operator == "GreaterThanThreshold" && aws_cloudwatch_metric_alarm.reader_write_allowed.period == 60 && aws_cloudwatch_metric_alarm.reader_write_allowed.evaluation_periods == 1
    error_message = "A single WRITE_PROBE ALLOWED in one minute must alarm."
  }
}

run "efs_and_backup_alarms_shape" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.efs_burst_credits_low.threshold == 1099511627776 && aws_cloudwatch_metric_alarm.efs_burst_credits_low.dimensions["FileSystemId"] == "fs-0123456789abcdef0"
    error_message = "EFS burst-credit alarm must use the 1 TiB default floor on the right file system."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.backup_failed.namespace == "AWS/Backup" && aws_cloudwatch_metric_alarm.backup_failed.metric_name == "NumberOfBackupJobsFailed" && aws_cloudwatch_metric_alarm.backup_failed.dimensions["BackupVaultName"] == "sefs-ut"
    error_message = "Backup alarm must watch failed jobs on our vault."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.nat_port_errors) == 2 && alltrue([for a in aws_cloudwatch_metric_alarm.nat_port_errors : a.metric_name == "ErrorPortAllocation"])
    error_message = "One ErrorPortAllocation alarm per NAT gateway."
  }
}

run "email_subscription_only_when_set" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 0
    error_message = "With alert_email null there must be no subscription."
  }
}

run "email_subscription_when_set" {
  command = apply
  module {
    source = "./modules/observability"
  }
  variables {
    alert_email = "ops@example.com"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1 && aws_sns_topic_subscription.email[0].protocol == "email" && aws_sns_topic_subscription.email[0].endpoint == "ops@example.com"
    error_message = "alert_email must create exactly one email subscription."
  }
}

run "rejects_bad_email_and_zero_floor" {
  command = plan
  module {
    source = "./modules/observability"
  }
  variables {
    alert_email                  = "not-an-email"
    efs_burst_credit_floor_bytes = 0
  }

  expect_failures = [var.alert_email, var.efs_burst_credit_floor_bytes]
}

run "dashboard_covers_apps_efs_nat_and_errors" {
  command = apply
  module {
    source = "./modules/observability"
  }

  assert {
    condition = alltrue([
      for needle in ["RunningTaskCount", "CPUUtilization", "BurstCreditBalance", "DataWriteIOBytes", "ErrorPortAllocation", "ReaderWriteAllowed"] :
      strcontains(aws_cloudwatch_dashboard.this.dashboard_body, needle)
    ])
    error_message = "Dashboard must show running tasks, CPU, EFS credits and I/O, NAT errors and the reader-write-allowed counter."
  }
  assert {
    condition = alltrue([
      for w in jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets :
      alltrue([for m in w.properties.metrics : can(m[0])])
    ])
    error_message = "Every dashboard metric entry must be an array (CloudWatch rejects a flat list: 'metrics has to be an array of array of strings')."
  }
  assert {
    condition     = aws_cloudwatch_dashboard.this.dashboard_name == "sefs-ut-overview" && length(aws_ce_cost_allocation_tag.project) == 0
    error_message = "Dashboard is <name>-overview; the cost allocation tag is opt-in (off by default)."
  }
}
