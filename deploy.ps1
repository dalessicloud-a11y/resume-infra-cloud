<#
.SYNOPSIS
    Deploys resume infrastructure (S3 + CloudFront) and uploads the PDF.

.DESCRIPTION
    Deploys the CloudFormation stack from template.yaml, uploads resume.pdf to S3
    on every run (unless -SkipUpload), and invalidates the CloudFront cache.
    Bucket name, distribution ID, and URL are read from stack outputs after deploy.

    The PDF is uploaded with Cache-Control max-age=300. CloudFront invalidation
    drops the CDN copy immediately; browsers may keep a copy for up to 5 minutes.

.PARAMETER StackName
    CloudFormation stack name (default: resume-stack)

.PARAMETER TemplateFile
    Path to the CloudFormation template (default: ./template.yaml)

.PARAMETER BucketName
    S3 bucket name. When omitted, a new stack uses the template default
    (caio-dalessi-resume) and an existing stack keeps its current bucket.

.PARAMETER ResumeFile
    Path to the resume PDF (default: ./resume.pdf)

.PARAMETER Region
    AWS region for the stack and the bucket (default: us-east-1).
    CloudFront invalidation always uses us-east-1, where that API lives.

.PARAMETER PriceClass
    Optional CloudFront price class override (PriceClass_100, PriceClass_200, PriceClass_All).

.PARAMETER Environment
    Optional Environment tag override.

.PARAMETER SkipUpload
    Deploy the stack only. Do not upload the PDF or invalidate CloudFront.

.PARAMETER ForceUpload
    Accepted for compatibility. The PDF is uploaded on every deploy anyway.

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

    [Parameter()]
    [string]$PriceClass = "",

    [Parameter()]
    [string]$Environment = "",

    [switch]$SkipUpload,

    [switch]$ForceUpload
)

$CacheControl = "max-age=300,public"
$CloudFrontRegion = "us-east-1"
$AllowedPriceClasses = @("PriceClass_100", "PriceClass_200", "PriceClass_All")

function Write-Info {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "✔ $Message" -ForegroundColor Green
}

function Stop-Deploy {
    param([string]$Message)
    Write-Host "✖ $Message" -ForegroundColor Red
    exit 1
}

function Test-Command {
    param([string]$Command, [string]$Name = $Command)
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Stop-Deploy "$Name não encontrado no PATH. Instale: $Command"
    }
}

function Get-StackOutput {
    param([Parameter(Mandatory)][string]$Key)

    $value = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue" `
        --output text 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Deploy "Falha ao ler o output '$Key':`n$value"
    }

    $text = "$value".Trim()
    if (-not $text -or $text -eq "None") {
        Stop-Deploy "Output '$Key' não encontrado no stack '$StackName'. Confira se o template atualizado foi aplicado."
    }
    return $text
}

Write-Info "Verificando pré-requisitos..."
Test-Command "aws" "AWS CLI v2"

if ($PriceClass -and $AllowedPriceClasses -notcontains $PriceClass) {
    Stop-Deploy "PriceClass inválida: $PriceClass. Use: $($AllowedPriceClasses -join ', ')"
}

try {
    $identity = aws sts get-caller-identity --output json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $identity.Arn) {
        throw "identity unavailable"
    }
    Write-Ok "AWS autenticado: $($identity.Arn)"
}
catch {
    Stop-Deploy "AWS CLI não configurado. Rode: aws configure"
}

if (-not (Test-Path $TemplateFile)) {
    Stop-Deploy "Template não encontrado: $TemplateFile"
}

$uploadPdf = -not $SkipUpload
if ($uploadPdf -and -not (Test-Path $ResumeFile)) {
    Stop-Deploy "PDF não encontrado: $ResumeFile`nUse -ResumeFile <path> ou coloque resume.pdf na raiz do repo."
}

if ($ForceUpload) {
    Write-Info "-ForceUpload não é mais necessário: o PDF é enviado em todo deploy (use -SkipUpload para não enviar)."
}

if (-not $BucketName) {
    Write-Info "BucketName não informado. Stack novo usa o default do template (caio-dalessi-resume); stack existente mantém o bucket atual."
}

Write-Info "Deploying CloudFormation stack: $StackName"

$deployArgs = @(
    "cloudformation", "deploy",
    "--stack-name", $StackName,
    "--template-file", $TemplateFile,
    "--region", $Region,
    "--no-fail-on-empty-changeset"
)

$overrides = @()
if ($BucketName) { $overrides += "BucketName=$BucketName" }
if ($PriceClass) { $overrides += "PriceClass=$PriceClass" }
if ($Environment) { $overrides += "Environment=$Environment" }
if ($overrides.Count -gt 0) {
    $deployArgs += "--parameter-overrides"
    $deployArgs += $overrides
}

$deployResult = aws @deployArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-Deploy "Stack deployment failed:`n$deployResult"
}
Write-Ok "Stack deployed (ou sem alterações)"

$resolvedBucket = Get-StackOutput -Key "BucketName"
$distributionId = Get-StackOutput -Key "DistributionId"
$url = Get-StackOutput -Key "CloudFrontURL"

if ($distributionId -notmatch '^E[A-Z0-9]+$') {
    Stop-Deploy "DistributionId inválido: '$distributionId'. A invalidação precisa do ID do CloudFront (ex.: E1A2B3C4D5E6F7), não do domínio."
}

if ($uploadPdf) {
    Write-Info "Uploading resume PDF to s3://$resolvedBucket/resume.pdf"
    $uploadResult = aws s3 cp $ResumeFile "s3://$resolvedBucket/resume.pdf" `
        --content-type "application/pdf" `
        --cache-control $CacheControl `
        --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Deploy "PDF upload failed:`n$uploadResult"
    }
    Write-Ok "PDF uploaded"

    Write-Info "Invalidating CloudFront cache ($distributionId)..."
    $invalidation = aws cloudfront create-invalidation `
        --distribution-id $distributionId `
        --paths "/*" `
        --region $CloudFrontRegion 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Deploy "CloudFront invalidation failed:`n$invalidation"
    }
    Write-Ok "Cache invalidation created (CDN imediato; o browser pode guardar o PDF por até 5 min)"
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " Your resume is live!" -ForegroundColor Green
Write-Host " $url" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Bucket:       $resolvedBucket" -ForegroundColor Gray
Write-Host "Distribution: $distributionId" -ForegroundColor Gray
Write-Host "Stack:        $StackName" -ForegroundColor Gray
Write-Host "Region:       $Region" -ForegroundColor Gray
