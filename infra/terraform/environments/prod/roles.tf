# No resources here — documenting a deliberate gap.
#
# The db_app_username Postgres ROLE (as opposed to its password, which is a
# plain Terraform variable — see variables.tf's db_app_password) is NOT
# created by this config. Reason: creating a Postgres role requires a provider
# that opens a real DB connection (e.g. cyrilgdn/postgresql), configured with
# aws_db_instance.postgres.address — a value that doesn't exist until the RDS
# instance itself is created in this same apply. Terraform provider
# configuration cannot cleanly depend on a resource created in the same run
# (the same chicken-and-egg class of problem solved for the state backend
# itself in infra/terraform/bootstrap/).
#
# Instead, the role is created by a short, idempotent follow-up step run once
# RDS is up and its endpoint is known: server/devops/provisionAwsAppRole.ts,
# invoked via `docker compose exec server ...` (this repo's Node tooling only
# runs inside containers — see root CLAUDE.md). It reads the password already
# stored in aws_secretsmanager_secret.postgres_app_credentials (so Secrets
# Manager stays the single source of truth for the value actually in use, even
# though you supplied it) and issues `CREATE ROLE .. LOGIN PASSWORD ..` (or
# `ALTER ROLE .. PASSWORD ..` if it already exists) plus `GRANT ALL
# PRIVILEGES` on db_name/schema public, using the RDS master credentials to
# connect. Documented as its own numbered step in
# server/docs/AWS-DEPLOY-COMMANDS-STEP-BY-STEP_V1.md.
