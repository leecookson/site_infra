
resource "aws_api_gateway_rest_api" "api" {
  name        = "CooksonProAPI"
  description = "API Gateway for CooksonPro Lambda"
}

// This is the existing proxy for the Node.js lambda.
// API Gateway uses a most-specific-path-first routing.
// A new, more specific resource for the Python lambda will be evaluated first.
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy_method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy_method.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api_handler.invoke_arn
  timeout_milliseconds    = 29000 # Max timeout for API Gateway integration
}

// Resources for the Python Lambda, routed under /py
resource "aws_api_gateway_resource" "py_resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "py"
}

resource "aws_api_gateway_resource" "py_proxy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.py_resource.id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "py_proxy_method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.py_proxy.id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "py_lambda" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.py_proxy.id
  http_method = aws_api_gateway_method.py_proxy_method.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.py_api_handler.invoke_arn
  timeout_milliseconds    = 29000 # Max timeout for API Gateway integration
}

resource "aws_api_gateway_stage" "aws_api_gateway_stage" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"

  deployment_id = aws_api_gateway_deployment.api_deployment.id

  variables = {
    api_version = var.api_version
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "py_apigw" {
  statement_id  = "AllowAPIGatewayInvokePy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.py_api_handler.function_name
  principal     = "apigateway.amazonaws.com"

  # You can make this more specific by referencing the method ARN for added security
  source_arn = "${aws_api_gateway_rest_api.api.execution_arn}/*/*${aws_api_gateway_resource.py_resource.path}/${aws_api_gateway_resource.py_proxy.path_part}"
}

resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [
    aws_api_gateway_integration.lambda,
    aws_api_gateway_integration.py_lambda,
  ]
  rest_api_id = aws_api_gateway_rest_api.api.id
}

# IAM Role for API Gateway to write to CloudWatch Logs
resource "aws_iam_role" "api_gateway_cloudwatch_role" {
  name = "api-gateway-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "API Gateway CloudWatch Role"
  }
}

# Attach the managed policy for API Gateway to push logs to CloudWatch
resource "aws_iam_role_policy_attachment" "api_gateway_cloudwatch_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
  role       = aws_iam_role.api_gateway_cloudwatch_role.name
}

# Set the CloudWatch Logs role ARN in API Gateway account settings
resource "aws_api_gateway_account" "api_gateway_account" {
  cloudwatch_role_arn = aws_iam_role.api_gateway_cloudwatch_role.arn

  depends_on = [
    aws_iam_role_policy_attachment.api_gateway_cloudwatch_policy
  ]
}
output "api_gateway_domain" {
  description = "The domain of the API Gateway"
  value       = "${aws_api_gateway_resource.proxy.id}/${aws_api_gateway_stage.aws_api_gateway_stage.stage_name}"
}
output "api_gateway_invoke_url" {
  description = "The invoke URL for the API Gateway"
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.us-east-1.amazonaws.com/${aws_api_gateway_stage.aws_api_gateway_stage.stage_name}"
}