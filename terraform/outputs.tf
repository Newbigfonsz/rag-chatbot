output "api_endpoint" {
  value = aws_apigatewayv2_stage.main.invoke_url
}
output "s3_bucket" {
  value = aws_s3_bucket.documents.id
}
output "knowledge_base_id" {
  value = aws_bedrockagent_knowledge_base.main.id
}
