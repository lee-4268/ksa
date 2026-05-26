"""
s3 - S3 업로드/다운로드/presign 유틸

담당 도메인: S3 객체 CRUD
주요 의존성: core.db, core.config
엔드포인트: 없음
"""

import logging
from pathlib import Path
from botocore.exceptions import ClientError
from fastapi import HTTPException

from .config import S3_BUCKET_NAME, ALLOWED_S3_READ_PREFIXES, ALLOWED_S3_DELETE_PREFIXES
from .db import get_s3_client

logger = logging.getLogger(__name__)


def _validate_s3_key(key: str, allowed_prefixes: tuple) -> None:
    """S3 키 검증: 경로 조작 방지 + prefix 제한."""
    normalized = key.replace("\\", "/")
    if ".." in normalized or normalized.startswith("/"):
        raise HTTPException(status_code=400, detail="잘못된 S3 키")
    if not any(normalized.startswith(p) for p in allowed_prefixes):
        raise HTTPException(status_code=403, detail="허용되지 않은 S3 경로")


def upload_to_s3(file_path: Path, s3_key: str) -> bool:
    """파일을 S3에 업로드. 성공 시 True 반환."""
    try:
        s3_client = get_s3_client()
        s3_client.upload_file(
            str(file_path),
            S3_BUCKET_NAME,
            s3_key,
            ExtraArgs={'ContentType': 'image/jpeg'}
        )
        logger.info(f"Uploaded to S3: s3://{S3_BUCKET_NAME}/{s3_key}")
        return True
    except ClientError as e:
        logger.error(f"S3 upload failed: {e}")
        return False
    except Exception as e:
        logger.error(f"S3 upload error: {e}")
        return False


def get_presigned_url(key: str, expires_in: int = 3600) -> str:
    """S3 presigned URL 생성 (다운로드용)."""
    _validate_s3_key(key, ALLOWED_S3_READ_PREFIXES)
    s3_client = get_s3_client()
    return s3_client.generate_presigned_url(
        'get_object',
        Params={'Bucket': S3_BUCKET_NAME, 'Key': key},
        ExpiresIn=expires_in
    )
