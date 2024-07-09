data "aws_region" "current" {}

data "aws_caller_identity" "this" {}

data "aws_ecr_authorization_token" "token" {}


# Configure AWS provider
provider "aws" {
  region = var.region
  # Make it faster by skipping something
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_credentials_validation = true
}
locals {
  source_path   = "code/online_process"
  path_include  = ["**"]
  path_exclude  = ["**/__pycache__/**"]
  files_include = setunion([for f in local.path_include : fileset(local.source_path, f)]...)
  files_exclude = setunion([for f in local.path_exclude : fileset(local.source_path, f)]...)
  files         = sort(setsubtract(local.files_include, local.files_exclude))

  dir_sha = sha1(join("", [for f in local.files : filesha1("${local.source_path}/${f}")]))
}
provider "docker" {
  registry_auth {
    address  = format("%v.dkr.ecr.%v.amazonaws.com", data.aws_caller_identity.this.account_id, data.aws_region.current.name)
    username = data.aws_ecr_authorization_token.token.user_name
    password = data.aws_ecr_authorization_token.token.password
  }
}
# Create S3 bucket for document uploads
resource "aws_s3_bucket" "doc_upload_bucket" {
  bucket = format("%v-%v-%v",var.upload_bucket,data.aws_caller_identity.this.account_id,random_pet.this.id)
  force_destroy = true
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "POST", "PUT"]
    allowed_origins = ["*"]
  }
}

module "docker_build" {
  source = "./modules/docker-build"

  create_ecr_repo = true
  ecr_repo        = random_pet.this.id
  ecr_repo_lifecycle_policy = jsonencode({
    "rules" : [
      {
        "rulePriority" : 1,
        "description" : "Keep only the last 2 images",
        "selection" : {
          "tagStatus" : "any",
          "countType" : "imageCountMoreThan",
          "countNumber" : 2
        },
        "action" : {
          "type" : "expire"
        }
      }
    ]
  })
  use_image_tag = false # If false, sha of the image will be used

  # use_image_tag = true
  # image_tag   = "2.0"

  source_path = local.source_path
  platform    = "linux/amd64"
  build_args = {
    FOO = "bar"
  }

  triggers = {
    dir_sha = local.dir_sha
  }
}


# Create Lambda function for online processing
resource "aws_lambda_function" "online_processor" {
  function_name = var.function_name
  timeout       = 900 # 15 minutes
  role          = aws_iam_role.iam_for_lambda.arn
  memory_size   = 1024
  architectures = ["x86_64"]
  image_uri = module.docker_build.image_uri
  package_type = "Image"

  vpc_config {
    subnet_ids         = [var.private_subnet_1,var.public_subnet_1]
    security_group_ids = [var.security_group]
  }
  logging_config {
    log_format = "Text"
  }

  environment {
    variables = {
      user_dict_bucket = aws_s3_bucket.doc_upload_bucket.id
      user_dict_prefix = "translate"
    }
  }
  depends_on = [
    aws_iam_role.iam_for_lambda,
    aws_cloudwatch_log_group.online_processor,
  ]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}
# Attach IAM policy to online processor Lambda role
resource "aws_iam_role_policy" "online_processor_policy" {
  name   = "online_processor_policy"
  role   = "iam_for_lambda"
  policy = data.aws_iam_policy_document.online_processor_policy_doc.json
}
resource "aws_cloudwatch_log_group" "online_processor" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 30
}
data "aws_iam_policy_document" "online_processor_policy_doc" {
  statement {
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:InvokeModel"
    ]
    resources = ["arn:aws:bedrock:*::foundation-model/*"]
  }
  statement {
    actions = [
      "dynamodb:GetItem"
    ]
    resources = ["arn:aws:dynamodb:*:*:table/*"]
  }
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject"
    ]
    resources = ["${aws_s3_bucket.doc_upload_bucket.arn}/*"]
  }
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }
}
data "aws_subnet" "selected" {
  id = var.private_subnet_1
}
# Create Glue connection for jobs
resource "aws_glue_connection" "glue_job_conn" {
  name = "glue-job-connection"
  connection_type = "NETWORK"
  physical_connection_requirements {
    availability_zone = data.aws_subnet.selected.availability_zone
    subnet_id         = var.private_subnet_1
    security_group_id_list = [var.security_group]
  }
}
# Upload ddb_write_job.py script to S3  
# todo
resource "aws_s3_bucket_object" "ddb_write_script" {
  bucket = aws_s3_bucket.doc_upload_bucket.id
  key    = "ddb_write_job.py"
  source = "./code/offline_process/ddb_write_job.py"
}
resource "aws_cloudwatch_log_group" "glue_python_job" {
    name              = "glue_python_job"
    retention_in_days = 14
  }
# Create Glue job to ingest knowledge to DynamoDB
resource "aws_glue_job" "ingest_ddb_job" {
  name              = "ingest_knowledge2ddb"
  role_arn          = aws_iam_role.glue_job_role.arn
  max_capacity      = 1
  max_retries       = 0
  connections       = [aws_glue_connection.glue_job_conn.name]
  glue_version = "1.0"
  depends_on = [ aws_glue_connection.glue_job_conn ]
  command {
    name = "pythonshell"
    script_location = "s3://${aws_s3_bucket_object.ddb_write_script.bucket}/${aws_s3_bucket_object.ddb_write_script.key}"
    python_version  = "3.9"
    
  }
  
  default_arguments = {
    "--dynamodb_table_name" = "rag-translate-table"
    "--REGION"              = var.region
    "--dictionary_name"     = "dictionary_1",
    "--additional-python-modules" = "boto3>=1.28.52,botocore>=1.31.52"
    "--bucket"              =  aws_s3_bucket.doc_upload_bucket.bucket
    "--object_key"          = "translate/dictionary_1/dictionary_1_part_a.json"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue_python_job.name
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
  }
}



# Create Glue job role and policy
resource "aws_iam_role" "glue_job_role" {
  name = "glue_job_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "glue.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "glue_job_policy" {
  name        = "glue_job_policy" 
  description = "Policy for Glue jobs"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable",
        "dynamodb:DescribeTable",
        "dynamodb:BatchWriteItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::*/*"
    },
    {
      "Effect": "Allow",
        "Action": [
          "ec2:CreateNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcEndpoints",
          "ec2:CreateTags"
        ],
        "Resource":"*"
    },
    {
      "Effect": "Allow",
        "Action": [
          "logs:CreateLogStream"
        ],
        "Resource": "arn:aws:logs:*:*:log-group:/*"
    },
    {
      "Effect": "Allow",
        "Action": [
          "glue:GetConnection"
        ],
        "Resource": "arn:aws:glue:*:*:*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "glue_job_policy_attach" {
  role       = aws_iam_role.glue_job_role.name
  policy_arn = aws_iam_policy.glue_job_policy.arn
}

resource "random_pet" "this" {
  length = 2
}
