"""cv-func-22p-9106: serves the CV from the private S3 bucket through a function URL.

Bucket and prefix come from the BUCKET and PREFIX environment variables.
Credentials come from the execution role (cv-lambda-role-22p-9106). No keys here.
"""
import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]
PLACEHOLDER = "{{HOSTED_ON}}"

s3 = boto3.client("s3")

# path -> (object name under PREFIX, content type)
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/cv.pdf": ("cv.pdf", "application/pdf"),
}

NOT_FOUND_PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>404 Not Found</title></head>
<body style="font-family: sans-serif; padding: 2rem">
<h1>404 Not Found</h1>
<p>There is nothing at this address. Go back to the <a href="/">CV</a>.</p>
</body></html>
"""


def html(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": body,
    }


def build_response(path, function_name):
    route = ROUTES.get(path)
    if route is None:
        return html(404, NOT_FOUND_PAGE)

    name, content_type = route
    try:
        data = s3.get_object(Bucket=BUCKET, Key=PREFIX + name)["Body"].read()
    except ClientError as err:
        print(json.dumps({"error": err.response["Error"]["Code"], "key": PREFIX + name}))
        return html(502, "<h1>502 Bad Gateway</h1><p>Could not read the CV from storage.</p>")

    headers = {"Content-Type": content_type}

    if name == "index.html":
        page = data.decode("utf-8").replace(PLACEHOLDER, f"Lambda {function_name}")
        headers["Cache-Control"] = "public, max-age=60"
        return {"statusCode": 200, "headers": headers, "body": page}

    if name == "cv.pdf":
        # binary: the function URL decodes this back to raw bytes because of the flag
        return {
            "statusCode": 200,
            "headers": headers,
            "body": base64.b64encode(data).decode("ascii"),
            "isBase64Encoded": True,
        }

    return {"statusCode": 200, "headers": headers, "body": data.decode("utf-8")}


def handler(event, context):
    start = time.perf_counter()
    path = event.get("rawPath") or "/"

    response = build_response(path, context.function_name)

    # one JSON line per request
    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": response["statusCode"],
        "ms": round((time.perf_counter() - start) * 1000, 1),
    }))
    return response
