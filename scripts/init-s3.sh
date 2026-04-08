#!/bin/bash
# Crée le bucket S3 local au démarrage de LocalStack
awslocal s3 mb s3://${S3_BUCKET:-barcodes} --region ${AWS_REGION:-eu-west-1}
echo "✓ Bucket '${S3_BUCKET:-barcodes}' créé"