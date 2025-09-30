#!/bin/bash
set -e

echo "🚀 Deploying AWS Immutable Audit Trail..."

mkdir -p builds

terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

echo ""
echo "📊 Deployment Information:"
terraform output

echo ""
echo "✅ Deployment complete!"
echo ""
echo "API Endpoint: $(terraform output -raw api_endpoint)"
