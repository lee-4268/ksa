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

# 허가번호 정규식 — 하이픈 정상 케이스
_LICENSE_RE = re.compile(r"\d{2}-\d{4}-\d{2}-\d{7}")
# 허가번호 — 공백/노이즈 사이에 숫자 그룹이 흩어진 경우 (psm 실패 후 폴백)
_LICENSE_LOOSE = re.compile(r"(\d{2})\D{0,3}(\d{4})\D{0,3}(\d{2})\D{0,3}(\d{7})")
# 호출명칭: "호출명칭 : XXX" 형식 (전각 콜론/공백 허용)
_CALLNAME_RE = re.compile(r"호출명칭\s*[：:：]?\s*([^\s\n]{2,40})")

# 숫자가 와야 할 자리에서 흔히 오인되는 문자 교정표
# $ → 3,  \ → 1,  { } | → 1,  O o → 0,  S → 5,  B → 8
_OCR_FIX_TABLE = str.maketrans({
    "$": "3", "§": "5",
    "\\": "1", "{": "1", "}": "1", "|": "1",
    "S": "5", "B": "8",
})


def _fix_and_find_license(text: str) -> str | None:
    """OCR 텍스트에서 허가번호를 여러 전략으로 추출."""
    # 전략 1: 원문 직접 매칭
    m = _LICENSE_RE.search(text)
    if m:
        return m.group(0)

    # 전략 2: 공백 제거 + 숫자 오인 교정 후 매칭
    no_space = re.sub(r"\s+", "", text)
    fixed = no_space.translate(_OCR_FIX_TABLE)
    m = _LICENSE_RE.search(fixed)
    if m:
        return m.group(0)

    # 전략 3: 구분자(하이픈·공백·노이즈) 사이의 숫자 그룹 느슨하게 매칭
    m = _LICENSE_LOOSE.search(fixed)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}-{m.group(4)}"

    return None


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

        # 7. OCR — 세 가지 psm 모드로 시도 후 합산
        #   psm 6: 단일 균일 텍스트 블록 (구조화된 문서)
        #   psm 11: 희소 텍스트 (레이아웃 무시, 숫자 흩어진 경우 유리)
        #   psm 3: 완전 자동 (폴백)
        texts = {}
        for psm in (6, 11, 3):
            try:
                texts[psm] = pytesseract.image_to_string(
                    img, lang="kor+eng", config=f"--psm {psm} --oem 3"
                )
            except Exception:
                texts[psm] = ""
            logger.info(f"OCR psm{psm}(앞200): {texts[psm][:200]!r}")

        combined = "\n".join(texts.values())

        # 8. 허가번호 추출 (3단계 전략)
        license_no = _fix_and_find_license(combined)

        # 9. 호출명칭 추출
        callnames = _CALLNAME_RE.findall(combined)

        return {
            "license_no": license_no,
            "callname": callnames[0] if callnames else None,
        }

    except Exception as e:
        logger.error(f"OCR scan error: {e}")
        raise HTTPException(status_code=500, detail="OCR 처리 중 오류가 발생했습니다.")
