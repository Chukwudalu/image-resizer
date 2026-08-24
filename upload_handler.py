import json
import uuid
import os
import boto3

BUCKET = "jeremiah-image-pipeline"
REGION = "us-west-2"

CORS_HEADERS = {
    "Access-Control-Allow-origin": "*",
    "Access-Control-Allow-Methods": "GET"
}

s3 = boto3.client("s3", region_name=REGION)

def handler(event, context):
    query = event.get("queryStringParameters") or {}
    filename = query.get("filename")

    if not filename:
        return {
            "statusCode": 400,
            "headers": CORS_HEADERS,
            "body": json.dumps({"error": "filename query parameter is required"}),
        }

    ext = os.path.splitext(filename)[1]
    key = f"uploads/{uuid.uuid4()}{ext}"

    presigned_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key},
        ExpiresIn=300,
    )

    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps({"uploadUrl": presigned_url, "key": key}),
    }