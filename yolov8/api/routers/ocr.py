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
    from PIL import Image, ImageFilter, ImageEnhance, ImageOps
    HAS_TESSERACT = True
except ImportError:
    HAS_TESSERACT = False
    logger.warning("pytesseract/Pillow 미설치 — OCR 기능 비활성화 (503 반환)")

# 허가번호: 00-0000-00-0000000 형식
# OCR이 하이픈을 공백/다른 문자로 오인하는 경우도 커버
_LICENSE_RE = re.compile(r"\d{2}[-\s]\d{4}[-\s]\d{2}[-\s]\d{7}")
# 호출명칭: "호출명칭 : XXX" 형식 (전각 콜론/공백 허용)
_CALLNAME_RE = re.compile(r"호출명칭\s*[：:：]?\s*([^\s\n]{2,40})")


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
        # 1. base64 → PIL Image
        raw = base64.b64decode(body.image)
        img = Image.open(io.BytesIO(raw))

        # 2. EXIF 회전 보정 (모바일 촬영 이미지)
        try:
            from PIL import ExifTags
            exif = img._getexif()
            if exif:
                orient_key = next(
                    (k for k, v in ExifTags.TAGS.items() if v == "Orientation"), None
                )
                if orient_key and orient_key in exif:
                    orientation = exif[orient_key]
                    if orientation == 3:
                        img = img.rotate(180, expand=True)
                    elif orientation == 6:
                        img = img.rotate(270, expand=True)
                    elif orientation == 8:
                        img = img.rotate(90, expand=True)
        except Exception:
            pass

        # 3. 그레이스케일 변환
        img = img.convert("L")

        # 4. 해상도 정규화 (최소 장변 2000px — 숫자 인식률에 직결)
        w, h = img.size
        long_side = max(w, h)
        if long_side < 2000:
            scale = 2000 / long_side
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

        # 5. 대비 강화 (숫자/한글 구분선 선명화)
        img = ImageEnhance.Contrast(img).enhance(2.0)

        # 6. 언샤프 마스크 (엣지 강화, SHARPEN보다 효과적)
        img = img.filter(ImageFilter.UnsharpMask(radius=1, percent=200, threshold=3))

        # 7. OCR — psm 6: 단일 균일 텍스트 블록 (확인증처럼 구조화된 문서에 최적)
        #          oem 3: LSTM 엔진 (숫자 인식 우수)
        #          tessedit_char_whitelist 미사용 → 한글+영숫자 모두 인식
        config = "--psm 6 --oem 3"
        text_6 = pytesseract.image_to_string(img, lang="kor+eng", config=config)

        # psm 6에서 실패 시 psm 3(자동)으로 폴백
        text_3 = pytesseract.image_to_string(img, lang="kor+eng", config="--psm 3 --oem 3")

        # 두 결과 합쳐서 정규식 탐색 (어느 쪽이든 인식되면 사용)
        combined = text_6 + "\n" + text_3
        logger.info(f"OCR psm6(앞200): {text_6[:200]!r}")
        logger.info(f"OCR psm3(앞200): {text_3[:200]!r}")

        licenses = _LICENSE_RE.findall(combined)
        callnames = _CALLNAME_RE.findall(combined)

        # 하이픈 오인 공백 → 표준 허가번호 형식으로 정규화
        license_no = None
        if licenses:
            license_no = re.sub(r"[-\s]+", "-", licenses[0])

        return {
            "license_no": license_no,
            "callname": callnames[0] if callnames else None,
        }

    except Exception as e:
        logger.error(f"OCR scan error: {e}")
        raise HTTPException(status_code=500, detail="OCR 처리 중 오류가 발생했습니다.")
