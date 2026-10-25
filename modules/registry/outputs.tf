output "parameter_names" {
  description = "Names of every published parameter."
  value       = sort([for p in aws_ssm_parameter.output : p.name])
}
