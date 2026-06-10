"""
utils - 공유 유틸리티 함수

담당 도메인: 메모리 체크, 임시파일 정리, 이미지 검증, rate limit, pandas lazy import 등
주요 의존성: core.config
엔드포인트: 없음
"""

import os
import gc
import threading
import logging
import time as _time_mod
from decimal import Decimal
from pathlib import Path

from fastapi import HTTPException, Request

from .config import MEMORY_THRESHOLD_PCT, ALLOWED_EXTENSIONS, _TRUST_PROXY

logger = logging.getLogger(__name__)

# ── 선택적 의존성 ──────────────────────────────────────────────
try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# pandas lazy import (메모리 ~150MB 절약)
HAS_PANDAS = True
pd = None  # placeholder


def _get_pandas():
    """pandas lazy loader — 첫 호출 시에만 import."""
    global pd, HAS_PANDAS
    if pd is not None:
        return pd
    try:
        import pandas as _pd
        pd = _pd
        return pd
    except ImportError:
        HAS_PANDAS = False
        logging.warning("pandas not installed - callname matching disabled")
        return None


# ── 메모리 모니터링 ────────────────────────────────────────────

def _log_mem(label: str):
    """현재 프로세스 RSS + 시스템 가용 메모리 로깅."""
    if not HAS_PSUTIL:
        return
    proc = psutil.Process()
    rss_mb = proc.memory_info().rss / (1024 * 1024)
    vm = psutil.virtual_memory()
    avail_mb = vm.available / (1024 * 1024)
    logger.info(f"[MEM] {label} | RSS={rss_mb:.0f}MB | avail={avail_mb:.0f}MB | sys={vm.percent}%")


def _release_memory():
    """gc.collect + Linux malloc_trim → pymalloc이 해제한 메모리를 OS에 실제 반환."""
    gc.collect()
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        libc.malloc_trim(0)
    except Exception:
        pass  # Windows / non-glibc → skip


def _check_memory(operation: str = "작업"):
    """메모리 사용률 체크. 임계치 초과 시 HTTPException 발생."""
    if not HAS_PSUTIL:
        return
    mem = psutil.virtual_memory()
    if mem.percent >= MEMORY_THRESHOLD_PCT:
        logger.warning(f"메모리 부족 ({mem.percent}%) — {operation} 차단")
        raise HTTPException(
            status_code=503,
            detail=f"서버 메모리 부족 ({mem.percent}%). 잠시 후 다시 시도해주세요."
        )


# ── 디스크 모니터링 ────────────────────────────────────────────

DISK_FREE_MIN_GB = float(os.environ.get("DISK_FREE_MIN_GB", "3.0"))


def _disk_free_gb(path: str = "/tmp") -> float:
    """지정 경로의 디스크 여유 공간(GB) 반환. 실패 시 무한대로 간주."""
    try:
        import shutil as _shutil
        usage = _shutil.disk_usage(path)
        return usage.free / (1024 ** 3)
    except Exception:
        return float('inf')


def _ensure_disk_space(operation: str = "작업", min_free_gb: float = None, path: str = "/tmp"):
    """디스크 여유 공간 체크. 임계치 미만이면 자동 정리 시도 후 재확인, 그래도 부족하면 503.

    DS xlsx 빌드처럼 수 GB 임시 파일을 만드는 작업 전에 호출.
    """
    threshold = min_free_gb if min_free_gb is not None else DISK_FREE_MIN_GB
    free_gb = _disk_free_gb(path)
    if free_gb >= threshold:
        return free_gb

    logger.warning(f"디스크 여유 부족 ({free_gb:.2f}GB < {threshold}GB) — {operation} 전 자동 정리 시도")
    try:
        _cleanup_stale_temp_files(max_age_seconds=300)  # 5분 이상된 임시파일 정리
    except Exception as e:
        logger.warning(f"자동 정리 실패: {e}")

    free_gb_after = _disk_free_gb(path)
    if free_gb_after < threshold:
        logger.error(f"디스크 여전히 부족 ({free_gb_after:.2f}GB) — {operation} 차단")
        raise HTTPException(
            status_code=503,
            detail=f"서버 디스크 부족 ({free_gb_after:.2f}GB 가용). 운영자에게 문의하세요."
        )
    logger.info(f"디스크 정리 후 회복 ({free_gb:.2f}GB → {free_gb_after:.2f}GB)")
    return free_gb_after


# ── 임시파일 정리 ─────────────────────────────────────────────

def _cleanup_stale_temp_files(max_age_seconds: int = 3600):
    """오래된 임시파일 자동 삭제 (서버 시작/주기적 실행)

    대상: ds_temp_*, ds_merged_*, ds_export_*, ds_bgxlsx_*, ds_xlsx_*, ds_{uuid}.*,
          tmp* (xlsxwriter/NamedTemporaryFile), cert_batch_*
    제외: ds_cache/ 디렉토리 (자체 TTL 관리)
    """
    ds_prefixes = ("ds_temp_", "ds_merged_", "ds_export_", "ds_bgxlsx_", "ds_xlsx_", "ds_xls_")
    now = _time_mod.time()
    removed = 0
    freed_bytes = 0
    try:
        for fname in os.listdir("/tmp"):
            should_check = False
            if any(fname.startswith(p) for p in ds_prefixes):
                should_check = True
            elif fname.startswith("ds_") and not fname.startswith("ds_cache"):
                should_check = True
            elif fname.startswith("tmp") and not fname.endswith(".conf"):
                should_check = True
            elif fname.startswith("cert_batch_"):
                should_check = True
            elif fname.startswith("cert_cache.db.tmp-"):
                should_check = True

            if not should_check:
                continue

            fpath = f"/tmp/{fname}"
            try:
                if os.path.isdir(fpath):
                    if fname.startswith(("cert_batch_", "ds_xlsxbuild_", "ds_")):
                        stat = os.stat(fpath)
                        if now - stat.st_mtime > max_age_seconds:
                            import shutil
                            shutil.rmtree(fpath, ignore_errors=True)
                            removed += 1
                    continue
                stat = os.stat(fpath)
                age = now - stat.st_mtime
                if age > max_age_seconds:
                    size = stat.st_size
                    os.remove(fpath)
                    removed += 1
                    freed_bytes += size
            except Exception:
                pass
    except Exception as e:
        logger.warning(f"temp cleanup scan 실패: {e}")
    if removed > 0:
        logger.info(f"temp cleanup: {removed}개 파일 삭제 ({freed_bytes // (1024*1024)}MB 확보)")
    return removed


# ── 이미지 검증 ───────────────────────────────────────────────

_IMAGE_MAGIC: list[tuple[bytes, int]] = [
    (b'\xff\xd8\xff', 0),           # JPEG
    (b'\x89PNG\r\n\x1a\n', 0),      # PNG
    (b'BM', 0),                     # BMP
    (b'RIFF', 0),                   # WEBP
]


def validate_image(file) -> bool:
    """업로드 파일 확장자 검사."""
    ext = Path(file.filename).suffix.lower()
    return ext in ALLOWED_EXTENSIONS


def validate_image_bytes(content: bytes) -> bool:
    """업로드된 파일 실제 내용의 이미지 시그니처(magic bytes) 검증."""
    if len(content) < 12:
        return False
    for magic, offset in _IMAGE_MAGIC:
        if content[offset:offset + len(magic)] == magic:
            if magic == b'RIFF':
                return content[8:12] == b'WEBP'
            return True
    return False


# ── 파일 유틸 ─────────────────────────────────────────────────

async def save_upload_file(file, upload_dir: Path) -> Path:
    """임시 디렉토리에 업로드 파일 저장."""
    import uuid
    ext = Path(file.filename).suffix.lower()
    unique_filename = f"{uuid.uuid4()}{ext}"
    file_path = upload_dir / unique_filename
    with open(file_path, "wb") as buffer:
        content = await file.read()
        buffer.write(content)
    return file_path


def cleanup_file(file_path: Path):
    """임시 파일 삭제."""
    try:
        if file_path.exists():
            file_path.unlink()
    except Exception:
        pass


# ── DynamoDB Decimal 변환 ─────────────────────────────────────

def decimal_to_native(obj):
    """DynamoDB Decimal 타입을 Python 기본 타입으로 변환 (JSON 직렬화용)"""
    if isinstance(obj, Decimal):
        if obj % 1 == 0:
            return int(obj)
        return float(obj)
    if isinstance(obj, dict):
        return {k: decimal_to_native(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [decimal_to_native(v) for v in obj]
    return obj


# ── Rate Limiting ─────────────────────────────────────────────

class SimpleRateLimiter:
    """IP별 슬라이딩 윈도우 Rate Limiter. 메모리: ~100B/IP."""
    def __init__(self):
        self._store: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def is_allowed(self, key: str, max_requests: int, window_seconds: int) -> bool:
        now = _time_mod.time()
        cutoff = now - window_seconds
        with self._lock:
            timestamps = self._store.get(key, [])
            timestamps = [t for t in timestamps if t > cutoff]
            if len(timestamps) >= max_requests:
                self._store[key] = timestamps
                return False
            timestamps.append(now)
            self._store[key] = timestamps
            return True

    def cleanup(self):
        now = _time_mod.time()
        cutoff = now - 3600
        with self._lock:
            stale = [k for k, v in self._store.items() if not v or v[-1] < cutoff]
            for k in stale:
                del self._store[k]


_rate_limiter = SimpleRateLimiter()


def _get_client_ip(request: Request) -> str:
    """TRUST_PROXY 설정에 따라 클라이언트 IP 반환."""
    if _TRUST_PROXY:
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            first = forwarded.split(",")[0].strip()
            if first:
                return first
    return request.client.host if request.client else "unknown"


def _check_rate_limit(request: Request, endpoint: str, max_req: int, window: int):
    """Rate limit 체크. 초과 시 429 반환."""
    ip = _get_client_ip(request)
    if not _rate_limiter.is_allowed(f"{endpoint}:{ip}", max_req, window):
        raise HTTPException(status_code=429, detail="요청 횟수 초과. 잠시 후 다시 시도해주세요.")
