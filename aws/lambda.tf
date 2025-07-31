# Try to dynamically build a Node.js lambda that can handle API requests

variable "api_repo_url" {
  description = "The URL of the Node.js application repository for the API handler"
  type        = string
  default     = "https://github.com/leecookson/cookson_pro_api.git"
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "CooksonProLambdaExecRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Effect = "Allow"
        Sid    = ""
      }
    ]
  })
}


resource "aws_secretsmanager_secret" "open_api_secret" {
  name        = "/apikeys/OPEN_API_KEY"
  description = "Secret for CooksonPro API access to weather API"
}

resource "aws_secretsmanager_secret" "astro_app_id" {
  name        = "/apikeys/ASTRO_APP_ID"
  description = "Secret for CooksonPro API access to weather API"
}

resource "aws_secretsmanager_secret" "astro_app_secret" {
  name        = "/apikeys/ASTRO_APP_SECRET"
  description = "Secret for CooksonPro API access to weather API"
}

resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "get_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:Get*"]
    resources = ["arn:aws:secretsmanager:*:*:secret:/apikeys/*"]
  }
}

resource "aws_iam_policy" "get_secrets" {
  name        = "LambdaGetSecretsPolicy"
  description = "Allows cooksonpro lambda to access api keys"
  policy      = data.aws_iam_policy_document.get_secrets.json
}
resource "aws_iam_role_policy_attachment" "get_secrets" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_policy.get_secrets.arn
}

resource "aws_lambda_function" "api_handler" {
  function_name = "CooksonProAPIHandler"
  handler       = "handler.handler"
  runtime       = "nodejs20.x"
  role          = aws_iam_role.lambda_exec_role.arn

  filename         = "cookson_pro_api/lambda.zip"
  source_code_hash = filebase64sha256("cookson_pro_api/lambda.zip")
}


