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
    from PIL import Image, ImageFilter, ImageEnhance
    HAS_TESSERACT = True
except ImportError:
    HAS_TESSERACT = False
    logger.warning("pytesseract/Pillow 미설치 — OCR 기능 비활성화 (503 반환)")

# 허가번호 정규식 — 하이픈 정상 케이스
_LICENSE_RE = re.compile(r"\d{2}-\d{4}-\d{2}-\d{7}")
# 허가번호 — 공백/노이즈 사이에 숫자 그룹이 흩어진 경우 (폴백)
_LICENSE_LOOSE = re.compile(r"(\d{2})\D{0,3}(\d{4})\D{0,3}(\d{2})\D{0,3}(\d{7})")
# 호출명칭: "호출명칭 : XXX" 형식 (전각 콜론/공백 허용)
_CALLNAME_RE = re.compile(r"호출명칭\s*[：:：]?\s*([^\s\n]{2,40})")

# 숫자 오인 문자 교정표
_OCR_FIX_TABLE = str.maketrans({
    "$": "3", "§": "5",
    "\\": "1", "{": "1", "}": "1", "|": "1",
    "S": "5", "B": "8",
})

# OSD 결과에서 회전각 파싱
_OSD_ROTATE_RE = re.compile(r"Rotate:\s*(\d+)")


def _fix_and_find_license(text: str) -> str | None:
    """OCR 텍스트에서 허가번호를 여러 전략으로 추출."""
    # 전략 1: 원문 직접 매칭
    m = _LICENSE_RE.search(text)
    if m:
        return m.group(0)

    # 전략 2: 공백 제거 + 오인 문자 교정 후 매칭
    fixed = re.sub(r"\s+", "", text).translate(_OCR_FIX_TABLE)
    m = _LICENSE_RE.search(fixed)
    if m:
        return m.group(0)

    # 전략 3: 숫자 그룹 느슨하게 매칭 후 재조합
    m = _LICENSE_LOOSE.search(fixed)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}-{m.group(4)}"

    return None


def _detect_rotation(img) -> int:
    """
    tesseract OSD(--psm 0)로 텍스트 방향 검출.
    확인증이 세로 부착된 경우 90/270도를 반환.
    실패 시 0 반환.
    """
    try:
        osd = pytesseract.image_to_osd(img, config="--psm 0", timeout=8)
        m = _OSD_ROTATE_RE.search(osd)
        if m:
            angle = int(m.group(1))
            logger.info(f"OSD 감지 회전각: {angle}°")
            return angle
    except Exception as e:
        logger.warning(f"OSD 실패 (무시): {e}")
    return 0


def _ocr_image(img, psm: int) -> str:
    """단일 PSM 모드로 OCR 수행. 실패 시 빈 문자열."""
    try:
        return pytesseract.image_to_string(
            img, lang="kor+eng", config=f"--psm {psm} --oem 3"
        )
    except Exception:
        return ""


class ScanBody(BaseModel):
    image: str  # base64 인코딩된 JPEG/PNG


@router.post("/scan")
async def scan_cert(request: Request, body: ScanBody):
    """
    확인증 이미지(base64) → OCR → 허가번호/호출명칭 반환.

    처리 순서 (최소 호출):
    1. 전처리 (그레이스케일, 리사이즈, 대비 강화)
    2. OSD로 회전각 자동 감지 → 1회 회전
    3. OCR psm 6 (구조화 문서) → 허가번호 추출 성공 시 즉시 반환
    4. 미검출 시 psm 11 (희소 텍스트) 1회 추가
    5. 그래도 미검출 시 90° 반대 방향 psm 6 1회 (OSD 오감지 대비)
    """
    await _verify_auth(request)

    if not HAS_TESSERACT:
        raise HTTPException(
            status_code=503,
            detail="OCR 기능을 사용할 수 없습니다. 서버에 tesseract-ocr-kor를 설치해 주세요.",
        )

    try:
        # 1. base64 → PIL Image + EXIF 회전 보정
        raw = base64.b64decode(body.image)
        img = Image.open(io.BytesIO(raw))

        try:
            from PIL import ExifTags
            exif = img._getexif()
            if exif:
                orient_key = next(
                    (k for k, v in ExifTags.TAGS.items() if v == "Orientation"), None
                )
                if orient_key and orient_key in exif:
                    _EXIF_ROTATE = {3: 180, 6: 270, 8: 90}
                    deg = _EXIF_ROTATE.get(exif[orient_key], 0)
                    if deg:
                        img = img.rotate(deg, expand=True)
        except Exception:
            pass

        # 2. 전처리
        img = img.convert("L")
        w, h = img.size
        long_side = max(w, h)
        if long_side < 1600:                          # 2000→1600: 속도·품질 균형
            scale = 1600 / long_side
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
        elif long_side > 3000:                        # 너무 크면 다운스케일
            scale = 3000 / long_side
            img = img.resize((int(w * scale), int(h * scale)), Image.LANCZOS)

        img = ImageEnhance.Contrast(img).enhance(2.0)
        img = img.filter(ImageFilter.UnsharpMask(radius=1, percent=200, threshold=3))

        # 3. OSD로 텍스트 방향 감지 후 회전 (1회)
        angle = _detect_rotation(img)
        if angle:
            img = img.rotate(angle, expand=True)

        # 4. OCR — 최소 호출, 성공 즉시 중단
        collected_texts = []

        # 4-a. psm 6 (구조화된 단일 텍스트 블록 — 확인증 최적)
        t6 = _ocr_image(img, 6)
        logger.info(f"OCR psm6 (앞200): {t6[:200]!r}")
        collected_texts.append(t6)
        license_no = _fix_and_find_license(t6)

        # 4-b. 미검출 시 psm 11 (희소 텍스트) 1회 추가
        if not license_no:
            t11 = _ocr_image(img, 11)
            logger.info(f"OCR psm11 (앞200): {t11[:200]!r}")
            collected_texts.append(t11)
            license_no = _fix_and_find_license("\n".join(collected_texts))

        # 4-c. OSD가 오감지한 경우 대비 — 90° 반전 후 psm 6 1회
        if not license_no:
            alt = img.rotate(90, expand=True)
            t_alt = _ocr_image(alt, 6)
            logger.info(f"OCR alt-90 psm6 (앞200): {t_alt[:200]!r}")
            collected_texts.append(t_alt)
            license_no = _fix_and_find_license("\n".join(collected_texts))

        combined = "\n".join(collected_texts)
        callnames = _CALLNAME_RE.findall(combined)

        return {
            "license_no": license_no,
            "callname": callnames[0] if callnames else None,
        }

    except Exception as e:
        logger.error(f"OCR scan error: {e}")
        raise HTTPException(status_code=500, detail="OCR 처리 중 오류가 발생했습니다.")
