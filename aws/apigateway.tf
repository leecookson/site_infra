
resource "aws_api_gateway_rest_api" "api" {
  name        = "CooksonProAPI"
  description = "API Gateway for CooksonPro Lambda"
}

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

resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on  = [aws_api_gateway_integration.lambda]
  rest_api_id = aws_api_gateway_rest_api.api.id
}

output "api_gateway_domain" {
  description = "The domain of the API Gateway"
  value       = "${aws_api_gateway_resource.proxy.id}/${aws_api_gateway_stage.aws_api_gateway_stage.stage_name}"
}
output "api_gateway_invoke_url" {
  description = "The invoke URL for the API Gateway"
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.us-east-1.amazonaws.com/${aws_api_gateway_stage.aws_api_gateway_stage.stage_name}"
}