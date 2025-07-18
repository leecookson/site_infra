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

resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "api_handler" {
  function_name = "CooksonProAPIHandler"
  handler       = "handler.handler"
  runtime       = "nodejs20.x"
  role          = aws_iam_role.lambda_exec_role.arn

  filename         = "cookson_pro_api/lambda.zip"
  source_code_hash = filebase64sha256("cookson_pro_api/lambda.zip")
}


