# Resume Infrastructure Deployment Script
# Usage: .\deploy.ps1

$StackName   = "resume-stack"
$Template    = "template.yaml"
$BucketName  = "caio-dalessi-resume"
$ResumeFile  = "C:\Users\cdalessi\Documents\Projetos\Caio Dalessi - Resume.pdf"
$Region      = "us-east-1"

Write-Host "==> Deploying CloudFormation stack: $StackName" -ForegroundColor Cyan

aws cloudformation deploy `
  --stack-name $StackName `
  --template-file $Template `
  --parameter-overrides BucketName=$BucketName `
  --region $Region `
  --capabilities CAPABILITY_IAM

if ($LASTEXITCODE -ne 0) {
  Write-Host "ERROR: Stack deployment failed." -ForegroundColor Red
  exit 1
}

Write-Host "==> Stack deployed. Uploading resume PDF..." -ForegroundColor Cyan

aws s3 cp $ResumeFile "s3://$BucketName/resume.pdf" `
  --content-type "application/pdf" `
  --region $Region

if ($LASTEXITCODE -ne 0) {
  Write-Host "ERROR: PDF upload failed." -ForegroundColor Red
  exit 1
}

Write-Host "==> Getting your resume URL..." -ForegroundColor Cyan

$Url = aws cloudformation describe-stacks `
  --stack-name $StackName `
  --region $Region `
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontURL'].OutputValue" `
  --output text

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host " Your resume is live!" -ForegroundColor Green
Write-Host " $Url" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Note: CloudFront may take 2-5 minutes to fully propagate." -ForegroundColor Gray
