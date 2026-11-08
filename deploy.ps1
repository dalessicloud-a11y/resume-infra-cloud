<#
.SYNOPSIS
    Deploys resume infrastructure (S3 + CloudFront) and uploads PDF.

.DESCRIPTION
    Deploys CloudFormation stack from template.yaml, uploads resume.pdf to S3,
    and invalidates CloudFront cache.

.PARAMETER StackName
    CloudFormation stack name (default: resume-stack)

.PARAMETER TemplateFile
    Path to CloudFormation template (default: ./template.yaml)

.PARAMETER BucketName
    S3 bucket name (default: auto-generated unique name)

.PARAMETER ResumeFile
    Path to resume PDF file (default: ./resume.pdf)

.PARAMETER Region
    AWS region (default: us-east-1)

.PARAMETER SkipUpload
    Skip PDF upload and cache invalidation (stack only)

.PARAMETER ForceUpload
    Upload PDF even if stack deployment had no changes

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
    [string]$Region = "us-east-1",

    [switch]$SkipUpload,

    [switch]$ForceUpload
)

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
function Write-Info  { Write-Host "==> $args" -ForegroundColor Cyan }
function Write-Ok    { Write-Host "✔ $args"  -ForegroundColor Green }
function Write-Warn  { Write-Host "⚠ $args"  -ForegroundColor Yellow }
function Write-Error { Write-Host "✖ $args"  -ForegroundColor Red; exit 1 }

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

# PDF existe? (só valida se não for SkipUpload)
$uploadPdf = -not $SkipUpload
if ($uploadPdf -and -not (Test-Path $ResumeFile)) {
    Write-Error "PDF não encontrado: $ResumeFile `nUse -ResumeFile <path> ou coloque resume.pdf na raiz do repo."
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
# Upload PDF + Invalidate Cache
# ────────────────────────────────────────────────────────────────
if ($uploadPdf -and ($stackChanged -or $ForceUpload)) {
    Write-Info "Uploading resume PDF to s3://$BucketName/resume.pdf"
    $uploadResult = aws s3 cp $ResumeFile "s3://$BucketName/resume.pdf" `
        --content-type "application/pdf" `
        --cache-control "max-age=31536000,public" `
        --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "PDF upload failed:`n$uploadResult"
    }
    Write-Ok "PDF uploaded"

    # Invalida CloudFront
    Write-Info "Invalidating CloudFront cache..."
    $distId = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" `
        --output text 2>$null
    if ($distId -match 'https://([^.]+)\.cloudfront\.net') {
        $distId = $matches[1]
        aws cloudfront create-invalidation `
            --distribution-id $distId `
            --paths "/*" `
            --region $Region | Out-Null
        Write-Ok "Cache invalidation created (ativa em ~1-2 min)"
    }
    else {
        Write-Warn "Não foi possível obter Distribution ID para invalidação"
    }
}
elseif ($uploadPdf) {
    Write-Info "Stack sem mudanças e -ForceUpload não usado. Pulando upload/invalidação."
    Write-Info "Use -ForceUpload para forçar re-upload do PDF."
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
