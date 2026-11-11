<#
.SYNOPSIS
    Deploys resume infrastructure (S3 + CloudFront) and uploads site files.

.DESCRIPTION
    Deploys CloudFormation stack from template.yaml, uploads index.html + resume.pdf
    to S3, and invalidates CloudFront cache.

.PARAMETER StackName
    CloudFormation stack name (default: resume-stack)

.PARAMETER TemplateFile
    Path to CloudFormation template (default: ./template.yaml)

.PARAMETER BucketName
    S3 bucket name (default: auto-generated unique name)

.PARAMETER ResumeFile
    Path to resume PDF file (default: ./resume.pdf)

.PARAMETER IndexFile
    Path to landing page HTML (default: ./index.html)

.PARAMETER Region
    AWS region (default: us-east-1)

.PARAMETER SkipUpload
    Skip file upload and cache invalidation (stack only)

.PARAMETER ForceUpload
    Upload files even if stack deployment had no changes

.EXAMPLE
    .\deploy.ps1

.EXAMPLE
    .\deploy.ps1 -BucketName meu-bucket-unico -ResumeFile "C:\path\cv.pdf"

.EXAMPLE
    .\deploy.ps1 -StackName prod-resume -Region sa-east-1 -SkipUpload

.EXAMPLE
    .\deploy.ps1 -ForceUpload
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$StackName = "resume-stack",

    [Parameter()]
    [string]$TemplateFile = "template.yaml",

    [Parameter()]
    [string]$BucketName = "",

    [Parameter()]
    [string]$ResumeFile = "resume.pdf",

    [Parameter()]
    [string]$IndexFile = "index.html",

    [Parameter()]
    [string]$Region = "us-east-1",

    [switch]$SkipUpload,

    [switch]$ForceUpload
)

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
function Write-Info  { Write-Host "==> $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "[OK] $args"  -ForegroundColor Green }
function Write-Warn  { Write-Host "[!] $args"  -ForegroundColor Yellow }
function Write-Error { Write-Host "[X] $args"  -ForegroundColor Red; exit 1 }

function Test-Command {
    param([string]$Command, [string]$Name = $Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Write-Error "$Name não encontrado no PATH. Instale: $Command"
    }
}

function Get-UniqueBucketName {
    $accountId = aws sts get-caller-identity --query Account --output text 2>$null
    if (-not $accountId) { return "resume-$(Get-Random -Minimum 100000 -Maximum 999999)" }
    "resume-$accountId-$Region".ToLower()
}

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────
Write-Info "Verificando pré-requisitos..."
Test-Command "aws" "AWS CLI v2"

# Verifica credenciais AWS
try {
    $identity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
    Write-Ok "AWS autenticado: $($identity.Arn)"
}
catch {
    Write-Error "AWS CLI não configurado. Rode: aws configure"
}

# Template existe?
if (-not (Test-Path $TemplateFile)) {
    Write-Error "Template não encontrado: $TemplateFile"
}

# Bucket name
if (-not $BucketName) {
    $BucketName = Get-UniqueBucketName
    Write-Warn "BucketName não informado. Gerado: $BucketName"
}

# Arquivos do site existem? (só valida se não for SkipUpload)
$uploadFiles = -not $SkipUpload
if ($uploadFiles -and -not (Test-Path $ResumeFile)) {
    Write-Error "PDF nao encontrado: $ResumeFile `nUse -ResumeFile 'C:\path\to\file.pdf' ou coloque resume.pdf na raiz do repo."
}
if ($uploadFiles -and -not (Test-Path $IndexFile)) {
    Write-Error "Landing page nao encontrada: $IndexFile `nUse -IndexFile '.\index.html' ou coloque index.html na raiz do repo."
}

# ────────────────────────────────────────────────────────────────
# Deploy CloudFormation
# ────────────────────────────────────────────────────────────────
Write-Info "Deploying CloudFormation stack: $StackName"

$deployArgs = @(
    "cloudformation", "deploy",
    "--stack-name", $StackName,
    "--template-file", $TemplateFile,
    "--parameter-overrides", "BucketName=$BucketName",
    "--region", $Region,
    "--no-fail-on-empty-changeset"
)
# Template não cria IAM — remove CAPABILITY_IAM desnecessário
# Se futuramente adicionar IAM, adicione: "--capabilities", "CAPABILITY_IAM"

$deployResult = aws @deployArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Stack deployment failed:`n$deployResult"
}
Write-Ok "Stack deployed (ou sem alterações)"

# Captura se houve mudança real no stack
$stackChanged = $deployResult -notmatch "No changes to deploy"

# ────────────────────────────────────────────────────────────────
# Upload site files + Invalidate Cache
# ────────────────────────────────────────────────────────────────
if ($uploadFiles -and ($stackChanged -or $ForceUpload)) {
    Write-Info "Uploading landing page to s3://$BucketName/index.html"
    $htmlResult = aws s3 cp $IndexFile "s3://$BucketName/index.html" `
        --content-type "text/html; charset=utf-8" `
        --cache-control "max-age=300,public" `
        --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "HTML upload failed:`n$htmlResult"
    }
    Write-Ok "Landing page uploaded"

    Write-Info "Uploading resume PDF to s3://$BucketName/resume.pdf"
    $uploadResult = aws s3 cp $ResumeFile "s3://$BucketName/resume.pdf" `
        --content-type "application/pdf" `
        --cache-control "max-age=31536000,public" `
        --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PDF upload failed:`n$uploadResult"
    }
    Write-Ok "PDF uploaded"

    # Invalida CloudFront (ID fisico da distribution, nao o hostname)
    Write-Info "Invalidating CloudFront cache..."
    $distId = aws cloudformation describe-stack-resources `
        --stack-name $StackName `
        --region $Region `
        --query "StackResources[?LogicalResourceId=='ResumeDistribution'].PhysicalResourceId" `
        --output text 2>$null
    if ($distId -match '^E[A-Z0-9]+$') {
        aws cloudfront create-invalidation `
            --distribution-id $distId `
            --paths "/*" `
            --region $Region | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Cache invalidation created (ativa em ~1-2 min)"
        }
        else {
            Write-Warn "Falha ao criar invalidacao do CloudFront"
        }
    }
    else {
        Write-Warn "Nao foi possivel obter Distribution ID para invalidacao"
    }
}
elseif ($uploadFiles) {
    Write-Info "Stack sem mudanças e -ForceUpload não usado. Pulando upload/invalidação."
    Write-Info "Use -ForceUpload para forçar re-upload dos arquivos."
}

# ────────────────────────────────────────────────────────────────
# Output URL
# ────────────────────────────────────────────────────────────────
$url = aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" `
    --output text 2>$null

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " Your resume is live!" -ForegroundColor Green
Write-Host " $url" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Bucket: $BucketName" -ForegroundColor Gray
Write-Host "Stack:  $StackName" -ForegroundColor Gray
Write-Host "Region: $Region" -ForegroundColor Gray
