import json
import os
import boto3
import base64
from datetime import datetime, timezone

s3 = boto3.client('s3')
bedrock_agent = boto3.client('bedrock-agent-runtime')
bedrock_runtime = boto3.client('bedrock-runtime')
bedrock_agent_client = boto3.client('bedrock-agent')

KNOWLEDGE_BASE_ID = os.environ.get('KNOWLEDGE_BASE_ID')
S3_BUCKET = os.environ.get('S3_BUCKET')
MODEL_ID = os.environ.get('MODEL_ID', 'amazon.nova-micro-v1:0')

def lambda_handler(event, context):
    path = event.get('rawPath', '')
    method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')
    for stage in ['/dev', '/staging', '/prod']:
        if path.startswith(stage):
            path = path[len(stage):] or '/'
            break
    try:
        if path == '/health': return health_check()
        elif path == '/chat' and method == 'POST': return chat(json.loads(event.get('body', '{}')))
        elif path == '/upload' and method == 'POST': return upload_document(json.loads(event.get('body', '{}')))
        elif path == '/documents' and method == 'GET': return list_documents()
        elif path == '/sync' and method == 'POST': return sync_knowledge_base()
        else: return response(404, {'error': f'Not found: {method} {path}'})
    except Exception as e:
        return response(500, {'error': str(e)})

def health_check():
    return response(200, {'status': 'healthy', 'service': 'rag-chatbot', 'knowledge_base_id': KNOWLEDGE_BASE_ID})

def chat(body):
    question = body.get('question', body.get('message', ''))
    if not question: return response(400, {'error': 'Question required'})
    try:
        result = bedrock_agent.retrieve_and_generate(
            input={'text': question},
            retrieveAndGenerateConfiguration={
                'type': 'KNOWLEDGE_BASE',
                'knowledgeBaseConfiguration': {
                    'knowledgeBaseId': KNOWLEDGE_BASE_ID,
                    'modelArn': f'arn:aws:bedrock:{os.environ.get("AWS_REGION", "us-east-1")}::foundation-model/{MODEL_ID}'
                }
            }
        )
        answer = result['output']['text']
        citations = []
        if 'citations' in result:
            for c in result['citations']:
                for ref in c.get('retrievedReferences', []):
                    citations.append({'text': ref.get('content', {}).get('text', '')[:200], 'source': ref.get('location', {}).get('s3Location', {}).get('uri', '')})
        return response(200, {'answer': answer, 'citations': citations[:3], 'source': 'knowledge_base'})
    except Exception as e:
        return chat_direct(question)

def chat_direct(question):
    result = bedrock_runtime.invoke_model(
        modelId=MODEL_ID, contentType='application/json', accept='application/json',
        body=json.dumps({'messages': [{'role': 'user', 'content': [{'text': question}]}], 'inferenceConfig': {'maxTokens': 1024}})
    )
    answer = json.loads(result['body'].read())['output']['message']['content'][0]['text']
    return response(200, {'answer': answer, 'citations': [], 'source': 'direct_model'})

def upload_document(body):
    filename = body.get('filename')
    content = body.get('content')
    content_base64 = body.get('content_base64')
    if not filename: return response(400, {'error': 'Filename required'})
    if not content and not content_base64: return response(400, {'error': 'Content required'})
    file_content = base64.b64decode(content_base64) if content_base64 else content.encode('utf-8')
    s3.put_object(Bucket=S3_BUCKET, Key=filename, Body=file_content)
    return response(200, {'message': f'{filename} uploaded', 'note': 'Run POST /sync to update knowledge base'})

def list_documents():
    result = s3.list_objects_v2(Bucket=S3_BUCKET)
    docs = [{'key': obj['Key'], 'size': obj['Size']} for obj in result.get('Contents', [])]
    return response(200, {'documents': docs, 'count': len(docs)})

def sync_knowledge_base():
    data_sources = bedrock_agent_client.list_data_sources(knowledgeBaseId=KNOWLEDGE_BASE_ID)
    if not data_sources.get('dataSourceSummaries'): return response(400, {'error': 'No data source found'})
    data_source_id = data_sources['dataSourceSummaries'][0]['dataSourceId']
    result = bedrock_agent_client.start_ingestion_job(knowledgeBaseId=KNOWLEDGE_BASE_ID, dataSourceId=data_source_id)
    return response(200, {'message': 'Sync started', 'job_id': result['ingestionJob']['ingestionJobId'], 'status': result['ingestionJob']['status']})

def response(code, body):
    return {'statusCode': code, 'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'}, 'body': json.dumps(body, default=str)}
