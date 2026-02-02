# RAG Chatbot Demo Script
# Usage: .\demo.ps1 -Setup | -Demo | -Destroy

param([switch]$Setup, [switch]$Destroy, [switch]$Demo)

if ($Setup) {
    Write-Host "🚀 Setting up RAG Chatbot..." -ForegroundColor Cyan
    Set-Location "$PSScriptRoot\terraform"
    
    terraform init
    terraform apply -auto-approve
    
    # Install Python deps
    pip install opensearch-py requests-aws4auth --quiet --break-system-packages 2>$null
    
    # Create index
    python create_index.py
    
    $API = terraform output -raw api_endpoint
    
    # Upload sample doc
    $doc = @{filename="company-info.txt"; content="Acme Corp - Founded 2020, CEO Jane Smith, 500 employees. Products: CloudSync Pro, DataVault, AIAssist. Vacation: 20 days PTO + 10 holidays. Remote: Hybrid 3 days office, 2 remote."} | ConvertTo-Json
    Invoke-RestMethod -Uri "$API/upload" -Method POST -Body $doc -ContentType "application/json"
    
    # Sync
    Invoke-RestMethod -Uri "$API/sync" -Method POST
    
    Write-Host "✅ Setup complete! Wait 2 min then run: .\demo.ps1 -Demo" -ForegroundColor Green
    Set-Location $PSScriptRoot
    exit
}

if ($Destroy) {
    Set-Location "$PSScriptRoot\terraform"
    $bucket = terraform output -raw s3_bucket 2>$null
    if ($bucket) {
        aws s3 rm "s3://$bucket" --recursive 2>$null
        aws s3api delete-objects --bucket $bucket --delete "$(aws s3api list-object-versions --bucket $bucket --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>$null
        aws s3api delete-objects --bucket $bucket --delete "$(aws s3api list-object-versions --bucket $bucket --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>$null
        aws s3 rb "s3://$bucket" 2>$null
    }
    terraform destroy -auto-approve
    Write-Host "✅ Destroyed!" -ForegroundColor Green
    Set-Location $PSScriptRoot
    exit
}

# Demo mode
Clear-Host
Write-Host "`n  🤖 RAG CHATBOT - LIVE DEMO" -ForegroundColor Cyan
Write-Host "  Chat with AI that knows YOUR documents`n" -ForegroundColor White

Set-Location "$PSScriptRoot\terraform"
$API = terraform output -raw api_endpoint 2>$null
if (-not $API) { Write-Host "Not deployed! Run: .\demo.ps1 -Setup" -ForegroundColor Red; exit }

Write-Host "  API: $API`n" -ForegroundColor DarkGray
Read-Host "  Press Enter to start"

Write-Host "`n  1️⃣  HEALTH CHECK" -ForegroundColor Yellow
Invoke-RestMethod -Uri "$API/health"
Read-Host "`n  Press Enter"

Write-Host "`n  2️⃣  DOCUMENTS" -ForegroundColor Yellow
(Invoke-RestMethod -Uri "$API/documents").documents
Read-Host "`n  Press Enter"

Write-Host "`n  3️⃣  RAG CHAT" -ForegroundColor Yellow
@("What is the vacation policy?", "Who is the CEO?", "What products does the company offer?") | ForEach-Object {
    Write-Host "`n  Q: $_" -ForegroundColor Cyan
    $r = Invoke-RestMethod -Uri "$API/chat" -Method POST -Body (@{question=$_} | ConvertTo-Json) -ContentType "application/json"
    Write-Host "  A: $($r.answer)" -ForegroundColor Green
    Read-Host "  Press Enter"
}

Write-Host "`n  ✅ DEMO COMPLETE!" -ForegroundColor Green
Write-Host "  GitHub: https://github.com/Newbigfonsz/rag-chatbot`n" -ForegroundColor DarkGray
Set-Location $PSScriptRoot
