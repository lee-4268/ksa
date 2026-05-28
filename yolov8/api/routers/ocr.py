"""
ocr - 확인증 스캔 OCR

주요 의존성: core.auth, pytesseract (선택적 — 미설치 시 503 반환)
엔드포인트:
    POST /ocr/scan   확인증 이미지 base64 → 허가번호/호출명칭 추출

설치 방법 (EC2):
    sudo apt-get install -y tesseract-ocr tesseract-ocr-kor
    pip install pytesseract Pillow
"""

import base64
import io
import logging
import re

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from core.auth import _verify_auth

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/ocr", tags=["ocr"])

try:
    import pytesseract
    from PIL import Image, ImageFilter
    HAS_TESSERACT = True
except ImportError:
    HAS_TESSERACT = False
    logger.warning("pytesseract/Pillow 미설치 — OCR 기능 비활성화 (503 반환)")

# 허가번호: 00-0000-00-0000000 형식
_LICENSE_RE = re.compile(r"\d{2}-\d{4}-\d{2}-\d{7}")
# 호출명칭: "호출명칭 : XXX" 형식 (전각 콜론/공백 허용)
_CALLNAME_RE = re.compile(r"호출명칭\s*[：:]?\s*([^\s\n]{2,40})")


class ScanBody(BaseModel):
    image: str  # base64 인코딩된 JPEG/PNG


@router.post("/scan")
async def scan_cert(request: Request, body: ScanBody):
    """
    확인증 이미지(base64)를 받아 pytesseract OCR로 텍스트 추출 후
    허가번호·호출명칭을 정규식으로 파싱해 반환.

    반환:
        license_no: str | None  — 추출된 허가번호 (없으면 null)
        callname:   str | None  — 추출된 호출명칭 (없으면 null)
    """
    await _verify_auth(request)

    if not HAS_TESSERACT:
        raise HTTPException(
            status_code=503,
            detail="OCR 기능을 사용할 수 없습니다. 서버에 tesseract-ocr-kor를 설치해 주세요.",
        )

    try:
        # 1. base64 → PIL Image (그레이스케일)
        raw = base64.b64decode(body.image)
        img = Image.open(io.BytesIO(raw)).convert("L")

        # 2. 해상도가 낮으면 업스케일 (OCR 인식률 향상)
        w, h = img.size
        if max(w, h) < 1400:
            scale = 1400 / max(w, h)
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

        # 3. 샤프닝으로 텍스트 엣지 강화
        img = img.filter(ImageFilter.SHARPEN)

        # 4. OCR (--psm 3: 완전 자동 페이지 레이아웃)
        text = pytesseract.image_to_string(
            img,
            lang="kor+eng",
            config="--psm 3 --oem 3",
        )

        logger.info(f"OCR 원문(앞 200자): {text[:200]!r}")

        # 5. 정규식 추출
        licenses = _LICENSE_RE.findall(text)
        callnames = _CALLNAME_RE.findall(text)

        return {
            "license_no": licenses[0] if licenses else None,
            "callname": callnames[0] if callnames else None,
        }

    except Exception as e:
        logger.error(f"OCR scan error: {e}")
        raise HTTPException(status_code=500, detail="OCR 처리 중 오류가 발생했습니다.")
