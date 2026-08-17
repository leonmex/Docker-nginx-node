output "tfstate_bucket" {
  description = "S3 bucket holding Terraform remote state (used by environments/prod's backend.tf)"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tflock_table" {
  description = "DynamoDB table used for Terraform state locking"
  value       = aws_dynamodb_table.tflock.name
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
