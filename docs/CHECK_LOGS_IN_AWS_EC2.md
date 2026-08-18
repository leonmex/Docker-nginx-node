Since there's no SSH on this instance, you get an interactive shell via AWS Systems Manager Session Manager instead — either through the browser (easiest) or the CLI.

Browser method:

Go to the AWS Console → EC2 → Instances
Select the instance (i-0f84cf9304e3517bc, tagged blablarags-prod-app)
Click Connect (top right)
Choose the Session Manager tab → click Connect
This opens a browser-based terminal directly on the instance (no key pair needed). Once you're in:


cd /opt/blablarags

# All services, last 50 lines
docker compose -f docker-compose.prod.yml logs --tail 50

# One service
docker compose -f docker-compose.prod.yml logs server --tail 100
docker compose -f docker-compose.prod.yml logs webapp --tail 100
docker compose -f docker-compose.prod.yml logs proxy --tail 100
docker compose -f docker-compose.prod.yml logs redis --tail 100

# Live-follow (this one DOES support streaming, unlike my SSM script)
docker compose -f docker-compose.prod.yml logs -f

# Container status
docker compose -f docker-compose.prod.yml ps
CLI method (if you have the AWS CLI configured locally with the terraform-deploy profile):


aws ssm start-session --target i-0f84cf9304e3517bc --profile terraform-deploy --region eu-central-1
Drops you into the same shell, then use the same docker compose logs commands above.