# ☁️ Resume Hosting on AWS — S3 + CloudFront

My first AWS cloud infrastructure project. A simple, serverless, and cost-effective way to host a PDF resume publicly on the internet using AWS managed services and Infrastructure as Code (IaC).

**Live:** https://d2ei9h2gh8lzqc.cloudfront.net

---

## 📐 Architecture

```
Browser → CloudFront (HTTPS) → S3 (private bucket)
```

| Layer | Service | Role |
|---|---|---|
| Storage | Amazon S3 | Stores the PDF privately |
| CDN | Amazon CloudFront | Delivers over HTTPS globally |
| Security | Origin Access Control (OAC) | CloudFront-only access to S3 |
| IaC | AWS CloudFormation | Reproducible infrastructure |

> The S3 bucket has **no public access**. Only CloudFront can read from it via OAC, preventing direct bucket exposure.

---

## 🛠️ Stack

- **AWS S3** — object storage for the PDF file
- **AWS CloudFront** — global CDN with HTTPS and custom response headers
- **AWS CloudFormation** — infrastructure defined as code (YAML)
- **AWS CLI** — deployment from the terminal

---

## 📁 Project Structure

```
resume-infra-cloud/
├── template.yaml    # CloudFormation template (S3 + CloudFront)
├── deploy.ps1       # Deployment script (PowerShell)
└── README.md        # This file
```

---

## 🚀 How to Deploy

### Prerequisites
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- An AWS account with permissions to create S3, CloudFront, and CloudFormation resources

### 1. Configure AWS credentials
```powershell
aws configure
```

### 2. Clone this repository
```powershell
git clone https://github.com/dalessicloud-a11y/resume-infra-cloud.git
cd resume-infra-cloud
```

### 3. Add your resume PDF
Place `resume.pdf` in the project folder, **or** pass the path when deploying:
```powershell
.\deploy.ps1 -ResumeFile "C:\path\to\your\resume.pdf"
```

### 4. Run the deployment script
```powershell
.\deploy.ps1
```

If you omit `-BucketName`, the script generates a unique name like `resume-<account-id>-us-east-1`.

This will:
1. Deploy the CloudFormation stack (S3 bucket + CloudFront distribution)
2. Upload your PDF to S3
3. Invalidate the CloudFront cache (when needed)
4. Print the live CloudFront URL

> First deployment takes ~3 minutes. CloudFront propagation may add another 2-5 minutes.

---

## 🔄 Updating the Resume

Easiest option — re-upload and invalidate cache via the script:

```powershell
.\deploy.ps1 -ForceUpload -ResumeFile "C:\path\to\your\resume.pdf"
```

Or do it manually with AWS CLI (replace bucket and distribution id with your values from the deploy output):

```powershell
aws s3 cp "path\to\your\resume.pdf" s3://YOUR_BUCKET_NAME/resume.pdf --content-type "application/pdf"
aws cloudfront create-invalidation --distribution-id YOUR_DISTRIBUTION_ID --paths "/*"
```

---

## 💰 Cost

This setup runs at effectively **$0/month** at personal traffic levels:

| Service | Free Tier | Typical cost |
|---|---|---|
| S3 | 5 GB storage, 20K GET requests/month | ~$0.00 |
| CloudFront | 1 TB transfer, 10M requests/month | ~$0.00 |
| CloudFormation | Free | $0.00 |

---

## 🔭 What I Learned

- How to create and configure an **S3 bucket** with public access blocked
- How **CloudFront OAC** (Origin Access Control) securely connects CloudFront to a private S3 bucket
- How to write a **CloudFormation template** to define cloud infrastructure as code
- How to set **response headers** in CloudFront to control browser behavior (inline PDF rendering)
- How to deploy and manage a stack using the **AWS CLI**

---

## 🗺️ Next Steps

- [ ] Add a custom domain with **Route 53** and **ACM** (SSL certificate)
- [ ] Build an HTML landing page to wrap the resume
- [ ] Add a CI/CD pipeline with **GitHub Actions** to auto-deploy on push
- [ ] Explore **AWS CDK** as an alternative to CloudFormation YAML

---

## 📄 License

MIT — feel free to use this as a template for your own resume hosting.
