# RAG Chatbot 🤖

**Chat with AI that knows YOUR documents** using AWS Bedrock Knowledge Bases.

**Author:** Alphonzo Jones Jr

## What is RAG?

RAG (Retrieval Augmented Generation) solves AI hallucination by grounding answers in YOUR data:
1. Upload documents → 2. Create embeddings → 3. Retrieve relevant chunks → 4. Generate accurate answers

## Quick Start
```powershell
# Deploy (~5 min)
.\demo.ps1 -Setup

# Run demo
.\demo.ps1 -Demo

# Destroy (avoid costs!)
.\demo.ps1 -Destroy
```

## Architecture
```
S3 (docs) → OpenSearch (vectors) → Bedrock KB (retrieve) → Nova (generate)
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| /health | GET | Health check |
| /upload | POST | Upload document |
| /documents | GET | List documents |
| /sync | POST | Index documents |
| /chat | POST | Ask questions |

## Cost Warning ⚠️

OpenSearch Serverless costs ~$175/month. **Always destroy after demos!**
