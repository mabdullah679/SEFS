output "alerts_topic_arn" {
  description = "SNS topic every alarm notifies."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "dashboard_url" {
  description = "Console URL of the dashboard."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "alarm_names" {
  description = "Every alarm this module manages."
  value = sort(concat(
    [for a in aws_cloudwatch_metric_alarm.service_down : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.nat_port_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.app_log_errors : a.alarm_name],
    [
      aws_cloudwatch_metric_alarm.efs_burst_credits_low.alarm_name,
      aws_cloudwatch_metric_alarm.efs_no_clients.alarm_name,
      aws_cloudwatch_metric_alarm.backup_failed.alarm_name,
      aws_cloudwatch_metric_alarm.reader_write_allowed.alarm_name,
    ],
  ))
}

output "metrics_namespace" {
  description = "Custom namespace of the log-derived metrics."
  value       = local.ns
}
