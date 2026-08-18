Here's the full picture, plus one thing that needs fixing before apply or DataGrip won't reach it at all.

⚠️ Stale IP lock: terraform.tfvars currently locks the RDS security group to 2.245.10.213/32, but this machine's current public IP is 77.183.158.143. If we apply as-is, DataGrip (and anything else on this network) will be refused at the SG level — connection will just time out. I'll update that CIDR to the current IP before the terraform plan/apply in the database phase, unless you're connecting from a different fixed IP DataGrip should use instead — let me know if so.

Once RDS is applied, connection details come from two places:

Endpoint/port/db name — Terraform outputs:

terraform output db_endpoint   # RDS hostname
terraform output db_port       # 5432
terraform output db_name       # blablarags
Credentials — pulled from Secrets Manager (never a plain Terraform output):

aws secretsmanager get-secret-value \
  --secret-id blablarags-prod-postgres-admin-credentials \
  --profile terraform-deploy --region eu-central-1 \
  --query SecretString --output text
Use the admin secret (admin_dba_bla) for DataGrip/DBA work — the app secret (app-dba-blablarags) is what the running server uses, keep DataGrip off that one.
DataGrip setup (PostgreSQL data source):

Field	Value
Host	the db_endpoint output
Port	5432
Database	blablarags
User	admin_dba_bla
Password	from the admin secret above
SSL	enable it, mode require (RDS supports TLS; verify-full would need AWS's RDS CA bundle imported — not necessary just for require)
So the practical order once we're in the database phase: apply Terraform with your current IP in the CIDR list → fetch the admin secret → plug those 5 values into a new DataGrip PostgreSQL data source. Want me to fix the CIDR in terraform.tfvars now, ahead of running the plan?



RDS is live — terraform apply succeeded, 4/4 resources created.

Endpoint: blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com:5432
DB name: blablarags
Admin user: admin_dba_bla (secret: blablarags-prod-postgres-admin-credentials)
App user: app-dba-blablarags (secret: blablarags-prod-postgres-app-credentials)
Security group: sg-0b82fec4a480850d2, locked to your current IP
This is also the connection info for DataGrip we discussed earlier — host/port/db/admin user are all set.

Next steps to make the database actually usable: check that nbgsys@gmail.com got the SNS budget-alert confirmation email (click it or alerts won't deliver), then run server/devops/provisionAwsAppRole.ts to create the real app-dba-blablarags Postgres role and run migrations against it. Let me check what exists for the fetch-secret script first.

Bash Check whether the fetch-secret script and app-role provisioning script exist