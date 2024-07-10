
### Terraform Deployment Steps
Follow these steps to deploy the resources using this Terraform configuration:

#### Prerequisites
- This Terraform deployment assume you already have vpc and subnet configured. you can visit s3 endpoint in you subnet. you have a security group that planed to apply to resources in this deployment.
- Install Terraform on your local machine or build server.
- Docker installed and runing on your local machine or build server

- Configure AWS credentials with appropriate permissions to create and manage the required resources.

#### Initialize Terraform

Navigate to the directory containing the Terraform configuration files.

Change variables configured in "terraform.tfvars"
```
vpc_id = "vpc-xxx"
public_subnet_1 = "subnet-xxx"
private_subnet_1 = "subnet-xxx"
security_group = "sg-xxx"
region = "us-east-1"
upload_bucket = "docupload"
function_name = "translate_tool"
```

Run the following command to initialize Terraform:
```
terraform init
```
Review the Execution Plan
Review the changes that Terraform will make by running:
```
terraform plan
```
Verify that the planned changes are correct and as expected.
Apply the Changes
If the execution plan looks good, apply the changes by running:
```
terraform apply
```
Review the output and confirm the changes by typing "yes" when prompted.

#### Monitor the Deployment

Terraform will start provisioning the resources. This process may take several minutes to complete.

You can monitor the progress in the Terraform output or by checking the respective AWS services (e.g., Lambda, ECR, S3, Glue) in the AWS Management Console.

#### Verify the Deployment

Once the deployment is complete, verify that all resources have been created successfully.
Check the Lambda function, ECR repository, S3 bucket, and Glue job in the AWS Management Console.

#### Clean Up (Optional)

If you want to remove all the resources created by this Terraform configuration, run the following command:

terraform destroy

Review the planned destruction and type "yes" when prompted to confirm.

