"""
storage - S3 업로드/다운로드/삭제 엔드포인트

담당 도메인: 파일 스토리지 관리
주요 의존성: core.auth, core.db, core.config, core.utils
엔드포인트:
    POST /upload/photo
    POST /upload/excel
    GET  /download/presigned
    GET  /download/photo
    DELETE /storage/{key:path}
"""

import logging
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import StreamingResponse
from botocore.exceptions import ClientError

from core.auth import _verify_auth, _require_owner_or_admin
from core.config import (
    S3_BUCKET_NAME, MAX_PHOTO_SIZE, MAX_EXCEL_SIZE,
    ALLOWED_S3_READ_PREFIXES, ALLOWED_S3_DELETE_PREFIXES,
)
from core.db import get_s3_client
from core.utils import validate_image, validate_image_bytes, _check_rate_limit

router = APIRouter(tags=["storage"])
logger = logging.getLogger(__name__)


def _validate_s3_key(key: str, allowed_prefixes: tuple) -> None:
    """S3 키 검증: 경로 조작 방지 + prefix 제한."""
    normalized = key.replace("\\", "/")
    if ".." in normalized or normalized.startswith("/"):
        raise HTTPException(status_code=400, detail="잘못된 S3 키")
    if not any(normalized.startswith(p) for p in allowed_prefixes):
        raise HTTPException(status_code=403, detail="허용되지 않은 S3 경로")


@router.post("/upload/photo")
async def upload_photo(
    file: UploadFile = File(...),
    owner: str = Form(...),
    stationId: str = Form(...),
    request: Request = None,
):
    """사진 S3 업로드."""
    await _require_owner_or_admin(request, owner)
    if not validate_image(file):
        raise HTTPException(status_code=400, detail="이미지 형식이 올바르지 않습니다")
    try:
        s3_client = get_s3_client()
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        ext = Path(file.filename).suffix.lower()
        s3_key = f"photos/{owner}/{stationId}/{timestamp}{ext}"
        content = await file.read()
        if len(content) > MAX_PHOTO_SIZE:
            raise HTTPException(
                status_code=400,
                detail=f"파일 크기 초과 (최대 {MAX_PHOTO_SIZE // 1024 // 1024}MB)",
            )
        if not validate_image_bytes(content):
            raise HTTPException(status_code=400, detail="이미지 형식이 올바르지 않습니다")
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType=file.content_type,
        )
        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.post("/upload/excel")
async def upload_excel(
    file: UploadFile = File(...),
    owner: str = Form(...),
    categoryName: str = Form(...),
    request: Request = None,
):
    """원본 Excel S3 업로드."""
    await _require_owner_or_admin(request, owner)
    if not file.filename.lower().endswith(('.xlsx', '.xls')):
        raise HTTPException(status_code=400, detail="엑셀 파일(.xlsx, .xls)만 업로드 가능합니다")
    try:
        s3_client = get_s3_client()
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_name = categoryName.replace("/", "_").replace("\\", "_")
        s3_key = f"excel/{owner}/{safe_name}_{timestamp}.xlsx"
        content = await file.read()
        if len(content) > MAX_EXCEL_SIZE:
            raise HTTPException(
                status_code=400,
                detail=f"파일 크기 초과 (최대 {MAX_EXCEL_SIZE // 1024 // 1024}MB)",
            )
        # XLSX: PK\x03\x04 (ZIP), XLS: OLE2 compound document \xd0\xcf\x11\xe0
        if len(content) >= 8 and content[:4] not in (b'PK\x03\x04', b'\xd0\xcf\x11\xe0'):
            raise HTTPException(status_code=400, detail="엑셀 파일 형식이 올바르지 않습니다")
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        )
        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/download/presigned")
async def get_presigned_url(
    key: str = Query(..., description="S3 object key"),
    request: Request = None,
):
    """S3 Presigned URL 생성 (다운로드용)."""
    await _verify_auth(request)
    _validate_s3_key(key, ALLOWED_S3_READ_PREFIXES)
    try:
        s3_client = get_s3_client()
        url = s3_client.generate_presigned_url(
            'get_object',
            Params={'Bucket': S3_BUCKET_NAME, 'Key': key},
            ExpiresIn=3600,
        )
        return {"success": True, "url": url, "expires_in": 3600}
    except ClientError as e:
        logger.error(f"Presigned URL error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/download/photo")
async def download_photo(
    key: str = Query(..., description="S3 object key"),
    request: Request = None,
):
    """S3 이미지를 EC2 경유로 스트리밍 (CORS 우회)."""
    await _verify_auth(request)
    _validate_s3_key(key, ALLOWED_S3_READ_PREFIXES)
    try:
        s3_client = get_s3_client()
        response = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=key)
        content_type = response.get("ContentType", "image/jpeg")
        if key.lower().endswith(".png"):
            content_type = "image/png"
        elif key.lower().endswith(".webp"):
            content_type = "image/webp"
        elif key.lower().endswith(".gif"):
            content_type = "image/gif"
        return StreamingResponse(
            response["Body"],
            media_type=content_type,
            headers={"Cache-Control": "public, max-age=86400"},
        )
    except ClientError as e:
        logger.error(f"S3 download error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.delete("/storage/{key:path}")
async def delete_s3_object(key: str, request: Request = None):
    """S3 객체 삭제."""
    await _verify_auth(request)
    _check_rate_limit(request, "storage_delete", 10, 60)
    _validate_s3_key(key, ALLOWED_S3_DELETE_PREFIXES)
    try:
        s3_client = get_s3_client()
        s3_client.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
        return {"success": True, "message": f"Deleted: {key}"}
    except ClientError as e:
        logger.error(f"S3 delete error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
