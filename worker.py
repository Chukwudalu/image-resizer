import json
import os
import signal
import tempfile
import time
import boto3
from resize import resize_image, SIZES

REGION = "us-west-2"
BUCKET = "jeremiah-image-pipeline"
QUEUE_URL = "https://sqs.us-west-2.amazonaws.com/458586357596/image-processing-queue"
METRIC_NAMESPACE = "ImagePipeline"

session = boto3.Session(region_name=REGION)
s3 = session.client("s3")
sqs = session.client("sqs")
cloudwatch = session.client("cloudwatch")


def emit_metric(name, value, unit="Count"):
    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[{
            "MetricName":name,
            "Value": value,
            "Unit": unit,
            "Dimensions": [{"Name": "Service", "Value": "ImageProcessingService"}]  
        }]
    )


def process_message(message):
    body = json.loads(message["Body"])
    key = body["Records"][0]["s3"]["object"]["key"]
    filename = os.path.basename(key)

    with tempfile.TemporaryDirectory() as tmpdir:
        local_input = os.path.join(tmpdir, filename)
        s3.download_file(BUCKET, key, local_input)

        resize_image(local_input, output_dir=tmpdir)

        base_name = os.path.splitext(filename)[0]
        for label in SIZES:
            local_output = os.path.join(tmpdir, f"{base_name}_{label}.jpg")
            s3_key = f"processed/{base_name}_{label}.jpg"
            s3.upload_file(local_output, BUCKET, s3_key)
            print(f"Uploaded s3://{BUCKET}/{s3_key}")



def main():
    print("Worker started, polling for messages...")
    running = True
    def handle_sigterm(signum, frame):
        nonlocal running
        print("SIGTERM received, shutting down after current iteration...")
        running = False

    signal.signal(signal.SIGTERM, handle_sigterm)
    
    while running:
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            # long polling: hold the connection open up to 20s
            WaitTimeSeconds=20,  
        )
        messages = response.get("Messages", [])
        if not messages:
            continue

        message = messages[0]
        start = time.monotonic()
        try:
            process_message(message)
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"])
            elapsed_ms = (time.monotonic() - start) * 1000
            emit_metric("ImagesProcessed", 1)
            emit_metric("ProcessingTime", elapsed_ms, unit="Milliseconds")
            print("Message processed and deleted.")
        except Exception as e:
            emit_metric("ProcessingFailures", 1)
            # SQS redelivers automatically, eventually to the DLQ
            print(f"Failed to process message: {e}")

    print("Worker exiting cleanly.")


if __name__ == "__main__":
    main()