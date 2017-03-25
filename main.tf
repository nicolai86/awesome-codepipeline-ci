provider "aws" {
  region = "${var.aws_region}"
}

variable "github_oauth_token" {
  default = ""
}

variable "aws_region" {
  default = "eu-west-1"
}

variable "aws_account_id" {
  default = ""
}

resource "aws_iam_role" "codebuild_role" {
  name = "codebuild-role-"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "codebuild_policy" {
  name        = "codebuild-policy"
  path        = "/service-role/"
  description = "Policy used in trust relationship with CodeBuild"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.ci.arn}",
        "${aws_s3_bucket.ci.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    }
  ]
}
POLICY
}

resource "aws_iam_policy_attachment" "codebuild_policy_attachment" {
  name       = "codebuild-policy-attachment"
  policy_arn = "${aws_iam_policy.codebuild_policy.arn}"
  roles      = ["${aws_iam_role.codebuild_role.id}"]
}

#
# CodeBuild configurations
#

resource "aws_codebuild_project" "unit-tests" {
  name          = "unit-tests"
  description   = "Run unit tests"
  build_timeout = "10"
  service_role  = "${aws_iam_role.codebuild_role.arn}"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "golang:1.8"
    type         = "LINUX_CONTAINER"
  }

  source {
    type     = "GITHUB"
    location = "https://github.com/nicolai86/traq.git"

    buildspec = <<EOF
version: 0.1

phases:
  install:
    commands:
      - go get github.com/nicolai86/traq

  build:
    commands:
      - go test ./...
EOF
  }
}

resource "aws_s3_bucket" "ci" {
  bucket = "awesome-codepipeline-ci-bucket"
  acl    = "private"
}

resource "aws_iam_role" "ci" {
  name = "test-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = "${aws_iam_role.ci.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.ci.arn}",
        "${aws_s3_bucket.ci.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

#
# CodePipeline configurations
#

resource "aws_codepipeline" "ci" {
  name     = "pr-template"
  role_arn = "${aws_iam_role.ci.arn}"

  artifact_store {
    location = "${aws_s3_bucket.ci.bucket}"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["test"]

      configuration {
        Owner      = "nicolai86"
        Repo       = "traq"
        Branch     = "master"
        OAuthToken = "${var.github_oauth_token}"
      }
    }
  }

  stage {
    name = "Test"

    action {
      name            = "Go"
      category        = "Test"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["test"]
      version         = "1"

      configuration {
        ProjectName = "${aws_codebuild_project.unit-tests.name}"
      }
    }
  }
}

#
# AWS Lamda
#

resource "aws_iam_policy" "cp-manager" {
    name = "cp-management"
    path = "/"
    description = "lambda pr policy"
    policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Stmt1476919244000",
            "Effect": "Allow",
            "Action": [
                "codepipeline:CreatePipeline",
                "codepipeline:DeletePipeline",
                "codepipeline:GetPipelineState",
                "codepipeline:ListPipelines",
                "codepipeline:GetPipeline",
                "codepipeline:UpdatePipeline",
                "iam:PassRole"
            ],
            "Resource": [
                "*"
            ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ],
          "Resource": "arn:aws:logs:*:*:*"
        }
    ]
}
EOF
}

resource "aws_iam_role" "cp-manager" {
    name = "cp-management"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "cp-manager-attach" {
    role = "${aws_iam_role.cp-manager.name}"
    policy_arn = "${aws_iam_policy.cp-manager.arn}"
}

resource "aws_lambda_function" "pr-handler" {
    filename = "handler.zip"
    function_name = "pr-handler"
    role = "${aws_iam_role.cp-manager.arn}"
    handler = "handler.Handle"
    source_code_hash = "${base64sha256(file("handler.zip"))}"
    memory_size = 256
    timeout = 300
    runtime = "python2.7"
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.pr-handler.arn}"
  principal     = "apigateway.amazonaws.com"

  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "arn:aws:execute-api:${var.aws_region}:${var.aws_account_id}:${aws_api_gateway_rest_api.gh.id}/*/POST/"
}

#
# AWS API Gateway
#

resource "aws_api_gateway_rest_api" "gh" {
  name        = "github"
  description = "api to handle github webhooks"
}

resource "aws_api_gateway_method" "webhooks" {
  rest_api_id = "${aws_api_gateway_rest_api.gh.id}"
  resource_id   = "${aws_api_gateway_rest_api.gh.root_resource_id}"
  http_method   = "POST"
  authorization = "NONE"
  request_parameters = {
    "method.request.header.X-GitHub-Event" = true
    "method.request.header.X-GitHub-Delivery" = true
  }
}

resource "aws_api_gateway_integration" "webhooks" {
  rest_api_id             = "${aws_api_gateway_rest_api.gh.id}"
  resource_id             = "${aws_api_gateway_rest_api.gh.root_resource_id}"
  http_method             = "${aws_api_gateway_method.webhooks.http_method}"
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.aws_region}:lambda:path/2015-03-31/functions/${aws_lambda_function.pr-handler.arn}/invocations"
  request_parameters = {
    "integration.request.header.X-GitHub-Event" = "method.request.header.X-GitHub-Event"
  }
  request_templates = {
    "application/json" = <<EOF
{
  "body" : $input.json('$'),
  "header" : {
    "X-GitHub-Event": "$input.params('X-GitHub-Event')",
    "X-GitHub-Delivery": "$input.params('X-GitHub-Delivery')"
  }
}
EOF
  }
}

resource "aws_api_gateway_integration_response" "webhook" {
  rest_api_id = "${aws_api_gateway_rest_api.gh.id}"
  resource_id = "${aws_api_gateway_rest_api.gh.root_resource_id}"
  http_method = "${aws_api_gateway_integration.webhooks.http_method}"
  status_code = "200"

  response_templates {
    "application/json" = "$input.path('$')"
  }

  response_parameters = {
    "method.response.header.Content-Type" = "integration.response.header.Content-Type"
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  selection_pattern = ".*"
}

resource "aws_api_gateway_method_response" "200" {
  rest_api_id = "${aws_api_gateway_rest_api.gh.id}"
  resource_id = "${aws_api_gateway_rest_api.gh.root_resource_id}"
  http_method = "${aws_api_gateway_method.webhooks.http_method}"
  status_code = "200"
  response_parameters = {
    "method.response.header.Content-Type" = true
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_deployment" "gh" {
  depends_on = ["aws_api_gateway_method.webhooks"]

  rest_api_id = "${aws_api_gateway_rest_api.gh.id}"
  stage_name  = "test"
}
