variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "allowed_cidr_blocks" {
  description = <<-EOT
    CIDR blocks allowed to reach Postgres on 5432. Starts as just your current
    IP (dynamic — update this list and re-apply when it changes). Add a second
    entry here once the app's compute location is decided.
  EOT
  type        = list(string)
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "blablarags"
}

variable "db_admin_username" {
  description = <<-EOT
    RDS master username — infra/DBA-level access only (creating the app role,
    emergency manual access). NOT what the running website/server app connects
    as day-to-day; see db_app_username. AWS constraint: 1-16 letters, numbers,
    or underscores, must start with a letter (checked via
    `aws rds create-db-instance help`).
  EOT
  type        = string
}

variable "db_admin_password" {
  description = <<-EOT
    RDS master password. Provided by you (server/docs/AWS-DEPLOY-PLAN-OK.md's
    "Where the secrets live" section), not Terraform-generated — set via
    TF_VAR_db_admin_password at plan/apply time, never committed to a
    tfvars file. AWS constraint: printable ASCII except / " @.
  EOT
  type        = string
  sensitive   = true
}

variable "db_app_username" {
  description = <<-EOT
    Application-level Postgres role — this is what server/src/config.ts's
    POSTGRES_USER should be set to for the running website/server app and for
    running migrations. Granted full rights on db_name (see roles.tf), kept
    distinct from db_admin_username so the app never holds the RDS master
    credential. The Postgres ROLE itself is created by
    server/devops/provisionAwsAppRole.ts, run once after `apply` (Terraform
    has no clean way to reach inside the DB to create it — see roles.tf). Not
    subject to the RDS master-username constraint (it's a plain Postgres role,
    not the RDS API's master-user field), so hyphens/length are fine.
  EOT
  type        = string
}

variable "db_app_password" {
  description = <<-EOT
    Application role password. Provided by you, not Terraform-generated —
    set via TF_VAR_db_app_password at plan/apply time, never committed to a
    tfvars file. Avoid @ : / ? # [ ] % — server/src/config.ts builds the
    postgresql:// URL without percent-encoding.
  EOT
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "Pinned to match local dev's Postgres 18.4 exactly"
  type        = string
  default     = "18.4"
}

variable "db_allocated_storage" {
  description = "Storage in GB"
  type        = number
  default     = 20
}

variable "alert_email" {
  description = "Email address for AWS Budgets cost alerts"
  type        = string
  default     = "nbgsys@gmail.com"
}

variable "budget_limit_eur" {
  description = "Account-wide monthly cost cap that triggers alert emails"
  type        = number
  default     = 40
}
