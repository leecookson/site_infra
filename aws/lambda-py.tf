# Try to dynamically build a Python lambda that can handle API requests
data "aws_caller_identity" "current" {}

variable "api_py_repo_url" {
  description = "The URL of the Python application repository for the API handler"
  type        = string
  default     = "https://github.com/leecookson/pyweb.git"
}
data "aws_ecr_image" "py_lambda" {
  repository_name = "pyweb-weather-lambda"
  image_tag       = var.py_image_hash
}

data "aws_iam_policy_document" "py_ecr_pull" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]
    # It's best practice to scope this to the specific ECR repository.
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${data.aws_ecr_image.py_lambda.repository_name}"]
  }
}

resource "aws_iam_policy" "py_ecr_pull" {
  name   = "LambdaECRPullPolicyPy"
  policy = data.aws_iam_policy_document.py_ecr_pull.json
}

resource "aws_iam_role_policy_attachment" "py_ecr_pull" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.py_ecr_pull.arn
}

resource "aws_lambda_function" "py_api_handler" {
  function_name = "pyapi"
  package_type  = "Image"
  image_uri     = data.aws_ecr_image.py_lambda.image_uri
  role          = aws_iam_role.lambda_exec_role.arn

  memory_size = 512
  timeout     = 29 # Must be <= API Gateway integration timeout

  architectures = ["arm64"]

  environment {
    variables = {
      OPEN_API_SECRET_NAME = aws_secretsmanager_secret.open_api_secret.name
    }
  }
}
