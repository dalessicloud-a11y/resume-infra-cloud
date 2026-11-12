#!/usr/bin/env bash
# Deploys resume infrastructure (S3 + CloudFront) and uploads the PDF.
#
# Deploys the CloudFormation stack from template.yaml, uploads resume.pdf on
# every run (unless --skip-upload), and invalidates the CloudFront cache.
# Bucket name, distribution ID, and URL are read from stack outputs.
#
# The PDF is uploaded with Cache-Control max-age=300. Invalidation drops the
# CDN copy immediately; browsers may keep a copy for up to 5 minutes.
#
# Usage:
#   ./deploy.sh
#   ./deploy.sh --bucket-name meu-bucket-unico --resume-file /path/cv.pdf
#   ./deploy.sh --stack-name prod-resume --region sa-east-1 --skip-upload
#   ./deploy.sh --force-upload
#
# CloudFront invalidation always uses us-east-1, where that API lives.

set -euo pipefail

StackName="resume-stack"
TemplateFile="template.yaml"
BucketName=""
ResumeFile="resume.pdf"
Region="us-east-1"
PriceClass=""
Environment=""
SkipUpload=0
ForceUpload=0

CacheControl="max-age=300,public"
CloudFrontRegion="us-east-1"

usage() {
    cat <<'EOF'
Usage: ./deploy.sh [options]

  --stack-name NAME       CloudFormation stack (default: resume-stack)
  --template-file PATH    Template path (default: ./template.yaml)
  --bucket-name NAME      S3 bucket. Omit to use the template default on create
                          (caio-dalessi-resume) or the current bucket on update.
  --resume-file PATH      Resume PDF (default: ./resume.pdf)
  --region REGION         Stack and bucket region (default: us-east-1)
  --price-class CLASS     PriceClass_100, PriceClass_200, or PriceClass_All
  --environment NAME      Environment tag override
  --skip-upload           Deploy the stack only
  --force-upload          Accepted for compatibility; upload already happens
  -h, --help              Show this help
EOF
}

info() { printf '==> %s\n' "$*"; }
ok() { printf '✔ %s\n' "$*"; }
die() { printf '✖ %s\n' "$*" >&2; exit 1; }

require_value() {
    if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
        die "Opção '$1' precisa de um valor. Rode ./deploy.sh --help"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack-name) require_value "$@"; StackName="$2"; shift 2 ;;
        --template-file) require_value "$@"; TemplateFile="$2"; shift 2 ;;
        --bucket-name) require_value "$@"; BucketName="$2"; shift 2 ;;
        --resume-file) require_value "$@"; ResumeFile="$2"; shift 2 ;;
        --region) require_value "$@"; Region="$2"; shift 2 ;;
        --price-class) require_value "$@"; PriceClass="$2"; shift 2 ;;
        --environment) require_value "$@"; Environment="$2"; shift 2 ;;
        --skip-upload) SkipUpload=1; shift ;;
        --force-upload) ForceUpload=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "Opção desconhecida: $1" ;;
    esac
done

stack_output() {
    local key="$1"
    local value
    if ! value="$(aws cloudformation describe-stacks \
        --stack-name "$StackName" \
        --region "$Region" \
        --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
        --output text)"; then
        die "Falha ao ler o output '$key'."
    fi
    value="$(printf '%s' "$value" | tr -d '[:space:]')"
    if [[ -z "$value" || "$value" == "None" ]]; then
        die "Output '$key' não encontrado no stack '$StackName'. Confira se o template atualizado foi aplicado."
    fi
    printf '%s' "$value"
}

info "Verificando pré-requisitos..."
command -v aws >/dev/null 2>&1 || die "AWS CLI não encontrado no PATH. Instale: aws"

case "$PriceClass" in
    "" | PriceClass_100 | PriceClass_200 | PriceClass_All) ;;
    *) die "PriceClass inválida: $PriceClass. Use: PriceClass_100, PriceClass_200, PriceClass_All" ;;
esac

if ! arn="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"; then
    die "AWS CLI não configurado. Rode: aws configure"
fi
ok "AWS autenticado: $arn"

[[ -f "$TemplateFile" ]] || die "Template não encontrado: $TemplateFile"

if [[ "$SkipUpload" -eq 0 && ! -f "$ResumeFile" ]]; then
    die "PDF não encontrado: $ResumeFile. Use --resume-file <path> ou coloque resume.pdf na raiz do repo."
fi

if [[ "$ForceUpload" -eq 1 ]]; then
    info "--force-upload não é mais necessário: o PDF é enviado em todo deploy (use --skip-upload para não enviar)."
fi

if [[ -z "$BucketName" ]]; then
    info "BucketName não informado. Stack novo usa o default do template (caio-dalessi-resume); stack existente mantém o bucket atual."
fi

info "Deploying CloudFormation stack: $StackName"

deploy_cmd=(
    aws cloudformation deploy
    --stack-name "$StackName"
    --template-file "$TemplateFile"
    --region "$Region"
    --no-fail-on-empty-changeset
)

overrides=()
[[ -n "$BucketName" ]] && overrides+=("BucketName=$BucketName")
[[ -n "$PriceClass" ]] && overrides+=("PriceClass=$PriceClass")
[[ -n "$Environment" ]] && overrides+=("Environment=$Environment")
if [[ ${#overrides[@]} -gt 0 ]]; then
    deploy_cmd+=(--parameter-overrides "${overrides[@]}")
fi

"${deploy_cmd[@]}"
ok "Stack deployed (ou sem alterações)"

resolved_bucket="$(stack_output BucketName)"
distribution_id="$(stack_output DistributionId)"
url="$(stack_output CloudFrontURL)"

if [[ ! "$distribution_id" =~ ^E[A-Z0-9]+$ ]]; then
    die "DistributionId inválido: '$distribution_id'. A invalidação precisa do ID do CloudFront (ex.: E1A2B3C4D5E6F7), não do domínio."
fi

if [[ "$SkipUpload" -eq 0 ]]; then
    info "Uploading resume PDF to s3://$resolved_bucket/resume.pdf"
    if ! upload_result="$(aws s3 cp "$ResumeFile" "s3://$resolved_bucket/resume.pdf" \
        --content-type "application/pdf" \
        --cache-control "$CacheControl" \
        --region "$Region" 2>&1)"; then
        die "PDF upload failed: ${upload_result}"
    fi
    ok "PDF uploaded"

    info "Invalidating CloudFront cache ($distribution_id)..."
    if ! invalidation="$(aws cloudfront create-invalidation \
        --distribution-id "$distribution_id" \
        --paths "/*" \
        --region "$CloudFrontRegion" 2>&1)"; then
        die "CloudFront invalidation failed: ${invalidation}"
    fi
    ok "Cache invalidation created (CDN imediato; o browser pode guardar o PDF por até 5 min)"
fi

printf '\n'
printf '================================================\n'
printf ' Your resume is live!\n'
printf ' %s\n' "$url"
printf '================================================\n\n'
printf 'Bucket:       %s\n' "$resolved_bucket"
printf 'Distribution: %s\n' "$distribution_id"
printf 'Stack:        %s\n' "$StackName"
printf 'Region:       %s\n' "$Region"
