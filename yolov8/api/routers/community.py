"""
community - 커뮤니티 게시판 엔드포인트

담당 도메인: 공지사항/요청사항/댓글/알림
주요 의존성: core.auth, core.db, core.config
엔드포인트:
    POST /community/upload-image
    POST /community/upload-file
    GET  /community/files/{file_key:path}
    GET  /community/images/{image_key:path}
    GET/POST/PUT/DELETE /community/notices/*
    GET  /community/stats
    GET/POST/PUT/DELETE /community/requests/*
    GET/POST /community/requests/{req_id}/comments
    PUT/DELETE /community/comments/{comment_id}
    GET /notifications
    POST /notifications/read-all
    POST /notifications/{notif_id}/read
"""

import asyncio
import json
import logging
import os
import re
import sqlite3
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import Response

from core.auth import (
    _verify_auth, _get_user_role_sync,
    _get_user_info_for_community, _list_all_users_sync,
    _hash_password, _count_daily_visitors,
)
from core.config import _COMMUNITY_DB, S3_BUCKET_NAME
from core.db import get_s3_client
from schemas.models import (
    NoticeCreate, NoticeUpdate, RequestCreate, RequestUpdate,
    RequestStatusUpdate, CommentCreate, CommentUpdate,
)

router = APIRouter(tags=["community"])
logger = logging.getLogger(__name__)

_COMMUNITY_IMAGE_ALLOWED_EXT = {'.jpg', '.jpeg', '.png', '.gif', '.webp'}
_COMMUNITY_IMAGE_MAX_SIZE = 5 * 1024 * 1024  # 5MB
_COMMUNITY_FILE_MAX_SIZE = 50 * 1024 * 1024  # 50MB
_COMMUNITY_FILE_CONTENT_TYPES = {
    '.pdf': 'application/pdf',
    '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.xls': 'application/vnd.ms-excel',
    '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.ppt': 'application/vnd.ms-powerpoint',
    '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.doc': 'application/msword',
    '.hwp': 'application/x-hwp',
    '.hwpx': 'application/x-hwpx',
    '.zip': 'application/zip',
    '.txt': 'text/plain',
    '.csv': 'text/csv',
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.gif': 'image/gif', '.webp': 'image/webp',
}


def _safe_community_key(key: str, allowed_prefix: str) -> str:
    """커뮤니티 S3 키 안전성 검증."""
    if not key or '..' in key or key.startswith('/'):
        raise HTTPException(400, "잘못된 키")
    if not key.startswith(allowed_prefix):
        if '/' in key:
            raise HTTPException(403, "허용되지 않은 경로")
        key = f"{allowed_prefix}{key}"
    return key


def _insert_notification(conn, user_empno: str, ntype: str, title: str, body: str,
                          related_type: str = '', related_id: int = 0):
    """알림 1건 INSERT (이미 열린 connection 사용)."""
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (user_empno, ntype, title, body, related_type, related_id, now),
    )


@router.post("/community/upload-image")
async def community_upload_image(request: Request, file: UploadFile = File(...)):
    """커뮤니티 게시판 이미지 업로드 → S3."""
    await _verify_auth(request)
    original_filename = file.filename or "image.jpg"
    ext = os.path.splitext(original_filename)[1].lower()
    if ext not in _COMMUNITY_IMAGE_ALLOWED_EXT:
        raise HTTPException(400, f"허용되지 않는 파일 형식입니다. ({', '.join(_COMMUNITY_IMAGE_ALLOWED_EXT)})")
    data = await file.read()
    if len(data) > _COMMUNITY_IMAGE_MAX_SIZE:
        raise HTTPException(400, f"파일 크기가 5MB를 초과합니다. ({len(data) / (1024*1024):.1f}MB)")
    safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', original_filename)
    s3_key = f"community-images/{uuid.uuid4().hex}_{safe_name}"
    content_type_map = {
        '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
        '.gif': 'image/gif', '.webp': 'image/webp',
    }
    content_type = content_type_map.get(ext, 'image/jpeg')
    try:
        s3_client = get_s3_client()
        s3_client.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=data, ContentType=content_type)
        logger.info(f"Community image uploaded: s3://{S3_BUCKET_NAME}/{s3_key} ({len(data)} bytes)")
    except Exception as e:
        logger.error(f"Community image upload failed: {e}")
        raise HTTPException(500, "이미지 업로드에 실패했습니다")
    return {"url": s3_key, "filename": original_filename}


@router.post("/community/upload-file")
async def community_upload_file(request: Request, file: UploadFile = File(...)):
    """커뮤니티 게시판 일반 파일 업로드 → S3."""
    await _verify_auth(request)
    original_filename = file.filename or "file"
    ext = os.path.splitext(original_filename)[1].lower()
    if ext not in _COMMUNITY_FILE_CONTENT_TYPES:
        raise HTTPException(400, f"허용되지 않는 파일 형식입니다. ({ext})")
    data = await file.read()
    if len(data) > _COMMUNITY_FILE_MAX_SIZE:
        raise HTTPException(400, f"파일 크기가 50MB를 초과합니다. ({len(data) / (1024*1024):.1f}MB)")
    safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', original_filename)
    s3_key = f"community-files/{uuid.uuid4().hex}_{safe_name}"
    content_type = _COMMUNITY_FILE_CONTENT_TYPES.get(ext, 'application/octet-stream')
    try:
        s3_client = get_s3_client()
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME, Key=s3_key, Body=data,
            ContentType=content_type,
            ContentDisposition=f'attachment; filename="{safe_name}"',
        )
        logger.info(f"Community file uploaded: s3://{S3_BUCKET_NAME}/{s3_key} ({len(data)} bytes)")
    except Exception as e:
        logger.error(f"Community file upload failed: {e}")
        raise HTTPException(500, "파일 업로드에 실패했습니다")
    return {"url": s3_key, "filename": original_filename, "size": len(data), "ext": ext}


@router.get("/community/files/{file_key:path}")
async def community_serve_file(file_key: str, request: Request):
    """커뮤니티 첨부파일 다운로드 — S3에서 스트리밍."""
    await _verify_auth(request)
    file_key = _safe_community_key(file_key, "community-files/")
    try:
        s3_client = get_s3_client()
        obj = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=file_key)
        data = obj['Body'].read()
        content_type = obj.get('ContentType', 'application/octet-stream')
        filename = file_key.split('/')[-1]
        if '_' in filename:
            filename = filename[filename.index('_') + 1:]
        return Response(
            content=data, media_type=content_type,
            headers={'Content-Disposition': f'attachment; filename="{filename}"'},
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Community file serve failed: {e}")
        raise HTTPException(404, "파일을 찾을 수 없습니다")


@router.get("/community/images/{image_key:path}")
async def community_serve_image(image_key: str):
    """커뮤니티 이미지 조회 — S3에서 직접 스트리밍 (인증 없음, UUID capability)."""
    image_key = _safe_community_key(image_key, "community-images/")
    ext = os.path.splitext(image_key)[1].lower()
    ct_map = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
              '.gif': 'image/gif', '.webp': 'image/webp'}
    content_type = ct_map.get(ext, 'image/jpeg')
    try:
        s3_client = get_s3_client()
        obj = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=image_key)
        data = obj['Body'].read()
        return Response(content=data, media_type=content_type)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Community image serve failed: {e}")
        raise HTTPException(404, "이미지를 찾을 수 없습니다")


@router.get("/community/notices")
async def list_notices(
    request: Request,
    division: str = Query(None),
    search: str = Query(None),
    page: int = Query(1, ge=1),
    pageSize: int = Query(20, ge=1, le=100),
):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            where_clauses = []
            params = []
            if division:
                where_clauses.append("division = ?")
                params.append(division)
            if search:
                where_clauses.append("(title LIKE ? OR content LIKE ?)")
                params.extend([f"%{search}%", f"%{search}%"])
            where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
            total = conn.execute(f"SELECT COUNT(*) FROM notices{where_sql}", params).fetchone()[0]
            offset = (page - 1) * pageSize
            rows = conn.execute(
                f"SELECT * FROM notices{where_sql} ORDER BY created_at DESC LIMIT ? OFFSET ?",
                params + [pageSize, offset],
            ).fetchall()
            notices = []
            for i, row in enumerate(rows):
                d = dict(row)
                d["번호"] = total - offset - i
                d["is_mine"] = (d.get("author_empno") == empno)
                notices.append(d)
            return {"notices": notices, "total": total}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.get("/community/notices/{notice_id}")
async def get_notice(notice_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT * FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            d = dict(row)
            d["is_mine"] = (d.get("author_empno") == empno)
            return d
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.post("/community/notices/{notice_id}/view")
async def increment_notice_view(notice_id: int, request: Request):
    await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE notices SET view_count = view_count + 1 WHERE id = ?", (notice_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.post("/community/notices")
async def create_notice(body: NoticeCreate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in ("admin", "manager"):
        raise HTTPException(403, "관리자 또는 매니저만 공지사항을 작성할 수 있습니다")
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            cur = conn.execute(
                "INSERT INTO notices (title, content, division, author_empno, author_name, author_org, author_role, images, attachments, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (body.title, body.content, body.division, empno, user_info["name"], user_info["org"],
                 role, json.dumps(body.images), json.dumps(body.attachments), now, now),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM notices WHERE id = ?", (cur.lastrowid,)).fetchone()
            return dict(row), cur.lastrowid
        finally:
            conn.close()

    result, notice_id = await asyncio.to_thread(_do)

    async def _send_notice_notifications():
        try:
            all_users = await asyncio.to_thread(_list_all_users_sync)
            division = body.division
            targets = [
                u for u in all_users
                if not u.get("is_dormant")
                and u.get("empno") != empno
                and (
                    division == '전체'
                    or division in (u.get("region") or '')
                    or u.get("role") == "admin"
                )
            ]

            def _bulk_insert():
                conn2 = sqlite3.connect(_COMMUNITY_DB, timeout=30)
                try:
                    _now = datetime.now(timezone.utc).isoformat()
                    notif_title = f'[{"전체" if division == "전체" else division}] 새 공지사항'
                    conn2.executemany(
                        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
                        "VALUES (?, 'notice', ?, ?, 'notice', ?, ?)",
                        [(u["empno"], notif_title, body.title[:60], notice_id, _now) for u in targets],
                    )
                    conn2.commit()
                finally:
                    conn2.close()

            if targets:
                await asyncio.to_thread(_bulk_insert)
        except Exception as e:
            logger.warning(f"공지 알림 발송 실패: {e}")

    asyncio.create_task(_send_notice_notifications())
    return {"success": True, "notice": result}


@router.put("/community/notices/{notice_id}")
async def update_notice(notice_id: int, body: NoticeUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE notices SET title = ?, content = ?, division = ?, images = ?, attachments = ?, updated_at = ? WHERE id = ?",
                (body.title, body.content, body.division, json.dumps(body.images), json.dumps(body.attachments), now, notice_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM notices WHERE id = ?", (notice_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "notice": result}


@router.delete("/community/notices/{notice_id}")
async def delete_notice(notice_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM notices WHERE id = ?", (notice_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.get("/community/stats")
async def community_stats(request: Request):
    """커뮤니티 요약 통계 (개인별 + 전체 요청 + 공지)."""
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            my_total = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=?", (empno,)).fetchone()[0]
            my_접수 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='접수'", (empno,)).fetchone()[0]
            my_처리중 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='처리중'", (empno,)).fetchone()[0]
            my_완료 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='완료'", (empno,)).fetchone()[0]
            all_total = conn.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
            all_접수 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='접수'").fetchone()[0]
            all_처리중 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='처리중'").fetchone()[0]
            all_완료 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='완료'").fetchone()[0]
            notice_total = conn.execute("SELECT COUNT(*) FROM notices").fetchone()[0]
            return {
                "my": {"total": my_total, "접수": my_접수, "처리중": my_처리중, "완료": my_완료},
                "all": {"total": all_total, "접수": all_접수, "처리중": all_처리중, "완료": all_완료},
                "notices": notice_total,
                "daily_visitors": _count_daily_visitors(),
            }
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.get("/community/requests")
async def list_requests(
    request: Request,
    status: str = Query(None),
    search: str = Query(None),
    page: int = Query(1, ge=1),
    pageSize: int = Query(20, ge=1, le=100),
):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            where_clauses = []
            params = []
            if status:
                where_clauses.append("status = ?")
                params.append(status)
            if search:
                where_clauses.append("(title LIKE ? OR content LIKE ?)")
                params.extend([f"%{search}%", f"%{search}%"])
            where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""
            total = conn.execute(f"SELECT COUNT(*) FROM requests{where_sql}", params).fetchone()[0]
            offset = (page - 1) * pageSize
            rows = conn.execute(
                f"SELECT * FROM requests{where_sql} ORDER BY created_at DESC LIMIT ? OFFSET ?",
                params + [pageSize, offset],
            ).fetchall()
            items = []
            for i, row in enumerate(rows):
                d = dict(row)
                d["번호"] = total - offset - i
                d["is_mine"] = (d.get("author_empno") == empno)
                if d["is_secret"] and d["author_empno"] != empno and role != "admin":
                    d["title"] = "비밀글입니다"
                    d["content"] = ""
                d.pop("secret_password", None)
                items.append(d)
            return {"requests": items, "total": total}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.get("/community/requests/{req_id}")
async def get_request_detail(req_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            d = dict(row)
            d["is_mine"] = (d.get("author_empno") == empno)
            if d["is_secret"] and d["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "비밀글은 작성자와 관리자만 열람할 수 있습니다")
            d.pop("secret_password", None)
            return d
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.post("/community/requests/{req_id}/view")
async def increment_request_view(req_id: int, request: Request):
    await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE requests SET view_count = view_count + 1 WHERE id = ?", (req_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.post("/community/requests")
async def create_request(body: RequestCreate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            hashed_pw = _hash_password(body.secret_password) if body.is_secret else ''
            cur = conn.execute(
                "INSERT INTO requests (title, content, is_secret, secret_password, author_empno, author_name, author_org, author_role, images, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (body.title, body.content, 1 if body.is_secret else 0, hashed_pw,
                 empno, user_info["name"], user_info["org"], role, json.dumps(body.images), now, now),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM requests WHERE id = ?", (cur.lastrowid,)).fetchone()
            return dict(row), cur.lastrowid
        finally:
            conn.close()

    result, request_id = await asyncio.to_thread(_do)

    try:
        all_users = await asyncio.to_thread(_list_all_users_sync)
        admins = [
            u for u in all_users
            if u.get("role") == "admin"
            and not u.get("is_dormant")
            and u.get("empno") != empno
        ]
        if admins:
            def _bulk():
                conn2 = sqlite3.connect(_COMMUNITY_DB, timeout=30)
                try:
                    _now = datetime.now(timezone.utc).isoformat()
                    author_name = user_info.get("name") or empno
                    conn2.executemany(
                        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
                        "VALUES (?, 'comment', ?, ?, 'request', ?, ?)",
                        [(u["empno"], '새로운 요청/문의가 등록되었습니다',
                          f'{author_name}: {body.title[:50]}', request_id, _now)
                         for u in admins],
                    )
                    conn2.commit()
                finally:
                    conn2.close()

            await asyncio.to_thread(_bulk)
    except Exception as e:
        logger.warning(f"요청 알림 발송 실패 (request_id={request_id}): {e}", exc_info=True)

    return {"success": True, "request": result}


@router.put("/community/requests/{req_id}")
async def update_request(req_id: int, body: RequestUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE requests SET title = ?, content = ?, images = ?, updated_at = ? WHERE id = ?",
                (body.title, body.content, json.dumps(body.images), now, req_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "request": result}


@router.delete("/community/requests/{req_id}")
async def delete_request(req_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM requests WHERE id = ?", (req_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.put("/community/requests/{req_id}/status")
async def update_request_status(req_id: int, body: RequestStatusUpdate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "관리자만 상태를 변경할 수 있습니다")
    valid_statuses = ("접수", "처리중", "완료")
    if body.status not in valid_statuses:
        raise HTTPException(400, f"유효하지 않은 상태: {body.status} (가능: {', '.join(valid_statuses)})")
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT id, author_empno, title FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            conn.execute(
                "UPDATE requests SET status = ?, updated_at = ? WHERE id = ?",
                (body.status, now, req_id),
            )
            req_author = row["author_empno"]
            if req_author and req_author != empno:
                label_map = {'처리중': '처리 중으로 변경되었습니다', '완료': '처리 완료되었습니다', '접수': '접수 상태로 변경되었습니다'}
                label = label_map.get(body.status, f'{body.status} 상태로 변경되었습니다')
                _insert_notification(
                    conn, req_author, 'status', '요청사항 상태가 변경되었습니다',
                    f'"{row["title"]}" 이(가) {label}', 'request', req_id,
                )
            conn.commit()
            updated = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "request": result}


@router.get("/community/requests/{req_id}/comments")
async def list_comments(req_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT * FROM comments WHERE request_id = ? ORDER BY created_at ASC", (req_id,)
            ).fetchall()
            result = []
            for r in rows:
                d = dict(r)
                d["is_mine"] = 1 if d.get("author_empno") == empno else 0
                result.append(d)
            return result
        finally:
            conn.close()

    comments = await asyncio.to_thread(_do)
    return {"comments": comments}


@router.post("/community/requests/{req_id}/comments")
async def create_comment(req_id: int, body: CommentCreate, request: Request):
    empno = await _verify_auth(request)
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.execute('PRAGMA foreign_keys = ON')
        conn.row_factory = sqlite3.Row
        try:
            req_row = conn.execute("SELECT id, author_empno, title FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not req_row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            parent_id = body.parent_id
            parent_author = None
            if parent_id is not None:
                parent_row = conn.execute(
                    "SELECT id, request_id, parent_id, author_empno FROM comments WHERE id = ?", (parent_id,)
                ).fetchone()
                if not parent_row:
                    raise HTTPException(404, "부모 댓글을 찾을 수 없습니다")
                if parent_row["request_id"] != req_id:
                    raise HTTPException(400, "부모 댓글이 다른 요청에 속해 있습니다")
                if parent_row["parent_id"] is not None:
                    raise HTTPException(400, "대대댓글은 허용되지 않습니다 (2단계까지만 가능)")
                parent_author = parent_row["author_empno"]
            cur = conn.execute(
                "INSERT INTO comments (request_id, parent_id, content, author_empno, author_name, author_org, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (req_id, parent_id, body.content, empno, user_info["name"], user_info["org"], now),
            )
            preview = body.content[:40] + ('...' if len(body.content) > 40 else '')
            if parent_id is not None:
                if parent_author and parent_author != empno:
                    _insert_notification(conn, parent_author, 'comment',
                                         '내 댓글에 답글이 달렸습니다',
                                         f'"{req_row["title"]}" — {preview}', 'request', req_id)
            else:
                req_author = req_row["author_empno"]
                if req_author and req_author != empno:
                    _insert_notification(conn, req_author, 'comment',
                                         '내 요청에 댓글이 달렸습니다',
                                         f'"{req_row["title"]}" — {preview}', 'request', req_id)
            conn.commit()
            row = conn.execute("SELECT * FROM comments WHERE id = ?", (cur.lastrowid,)).fetchone()
            d = dict(row)
            d["is_mine"] = 1
            return d
        finally:
            conn.close()

    comment = await asyncio.to_thread(_do)
    return {"success": True, "comment": comment}


@router.put("/community/comments/{comment_id}")
async def update_comment(comment_id: int, body: CommentUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM comments WHERE id = ?", (comment_id,)).fetchone()
            if not row:
                raise HTTPException(404, "댓글을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE comments SET content = ?, updated_at = ? WHERE id = ?",
                (body.content, now, comment_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM comments WHERE id = ?", (comment_id,)).fetchone()
            d = dict(updated)
            d["is_mine"] = 1
            return d
        finally:
            conn.close()

    comment = await asyncio.to_thread(_do)
    return {"success": True, "comment": comment}


@router.delete("/community/comments/{comment_id}")
async def delete_comment(comment_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM comments WHERE id = ?", (comment_id,)).fetchone()
            if not row:
                raise HTTPException(404, "댓글을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM comments WHERE id = ?", (comment_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.get("/notifications")
async def get_notifications(request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT * FROM notifications WHERE user_empno = ? "
                "ORDER BY is_read ASC, created_at DESC LIMIT 50",
                (empno,),
            ).fetchall()
            items = [dict(r) for r in rows]
            unread = sum(1 for r in items if r["is_read"] == 0)
            return {"unread_count": unread, "items": items}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@router.post("/notifications/read-all")
async def read_all_notifications(request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE notifications SET is_read = 1 WHERE user_empno = ?", (empno,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@router.post("/notifications/{notif_id}/read")
async def read_notification(notif_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute(
                "UPDATE notifications SET is_read = 1 WHERE id = ? AND user_empno = ?",
                (notif_id, empno),
            )
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}
