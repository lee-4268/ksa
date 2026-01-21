"""
데이터 준비 유틸리티
국소 형태정보 CSV/Excel과 이미지를 기반으로 학습 데이터셋 구성
"""

import os
import shutil
import random
import argparse
from pathlib import Path
from typing import Dict, List, Tuple, Optional
import pandas as pd
from tqdm import tqdm


# 형태 분류 매핑 (국소 형태정보 → 클래스명) - 9개 클래스
# 실제 데이터에 맞게 수정 필요
TYPE_MAPPING = {
    # 간이폴, 분산폴 및 비기준 설치대
    '간이폴': 'simple_pole',
    '분산폴': 'simple_pole',
    '비기준 설치대': 'simple_pole',
    '간이폴, 분산폴 및 비기준 설치대': 'simple_pole',

    # 강관주
    '강관주': 'steel_pipe',
    '강관': 'steel_pipe',

    # 복합형
    '복합형': 'complex_type',
    '복합': 'complex_type',

    # 옥내, 터널, 지하 등
    '옥내': 'indoor',
    '터널': 'indoor',
    '지하': 'indoor',
    '옥내, 터널, 지하 등': 'indoor',

    # 원폴(건물)
    '원폴(건물)': 'single_pole_building',
    '원폴_건물': 'single_pole_building',

    # 철탑(건물)
    '철탑(건물)': 'tower_building',
    '철탑_건물': 'tower_building',

    # 철탑(지면)
    '철탑(지면)': 'tower_ground',
    '철탑_지면': 'tower_ground',
    '철탑': 'tower_ground',

    # 통신주
    '통신주': 'telecom_pole',

    # 프레임
    '프레임': 'frame_mount',
}


def load_metadata(metadata_path: str) -> pd.DataFrame:
    """
    국소 형태정보 메타데이터 로드

    Args:
        metadata_path: CSV 또는 Excel 파일 경로

    Returns:
        DataFrame with columns: [국소ID, 형태, 이미지경로] (또는 유사한 컬럼)
    """
    path = Path(metadata_path)

    if path.suffix.lower() == '.csv':
        df = pd.read_csv(metadata_path, encoding='utf-8')
    elif path.suffix.lower() in ['.xlsx', '.xls']:
        df = pd.read_excel(metadata_path)
    else:
        raise ValueError(f"지원하지 않는 파일 형식: {path.suffix}")

    print(f"메타데이터 로드 완료: {len(df)}개 레코드")
    print(f"컬럼: {list(df.columns)}")

    return df


def map_type_to_class(type_name: str) -> Optional[str]:
    """형태 이름을 클래스명으로 매핑"""
    type_name = str(type_name).strip()

    # 직접 매핑 시도
    if type_name in TYPE_MAPPING:
        return TYPE_MAPPING[type_name]

    # 부분 매칭 시도
    for key, value in TYPE_MAPPING.items():
        if key in type_name:
            return value

    return None


def prepare_classification_dataset(
    metadata_path: str,
    image_dir: str,
    output_dir: str,
    type_column: str = '형태',
    image_column: str = '이미지경로',
    id_column: str = '국소ID',
    train_ratio: float = 0.8,
    seed: int = 42
):
    """
    YOLOv8 Classification 형식으로 데이터셋 구성

    구조:
    output_dir/
    ├── train/
    │   ├── dispersed_pole/
    │   ├── single_pole/
    │   ├── eco_friendly/
    │   ├── utility_pole/
    │   └── steel_pipe/
    └── val/
        ├── dispersed_pole/
        └── ...
    """
    random.seed(seed)

    # 메타데이터 로드
    df = load_metadata(metadata_path)

    # 컬럼 확인
    required_cols = [type_column]
    for col in required_cols:
        if col not in df.columns:
            print(f"경고: '{col}' 컬럼이 없습니다. 사용 가능한 컬럼: {list(df.columns)}")
            return

    # 출력 디렉토리 생성
    output_path = Path(output_dir)
    classes = [
        'simple_pole',           # 간이폴, 분산폴 및 비기준 설치대
        'steel_pipe',            # 강관주
        'complex_type',          # 복합형
        'indoor',                # 옥내, 터널, 지하 등
        'single_pole_building',  # 원폴(건물)
        'tower_building',        # 철탑(건물)
        'tower_ground',          # 철탑(지면)
        'telecom_pole',          # 통신주
        'frame_mount',           # 프레임
    ]

    for split in ['train', 'val']:
        for cls in classes:
            (output_path / split / cls).mkdir(parents=True, exist_ok=True)

    # 이미지 디렉토리 설정
    image_base = Path(image_dir)

    # 클래스별 이미지 수집
    class_images: Dict[str, List[Tuple[str, Path]]] = {cls: [] for cls in classes}
    unmapped_types = set()
    missing_images = []

    print("\n데이터 분류 중...")
    for idx, row in tqdm(df.iterrows(), total=len(df)):
        type_name = row[type_column]
        cls = map_type_to_class(type_name)

        if cls is None:
            unmapped_types.add(str(type_name))
            continue

        # 이미지 경로 결정
        if image_column in df.columns and pd.notna(row[image_column]):
            img_path = image_base / row[image_column]
        elif id_column in df.columns:
            # 국소ID로 이미지 찾기 (다양한 확장자 시도)
            img_id = str(row[id_column])
            img_path = None
            for ext in ['.jpg', '.jpeg', '.png', '.bmp', '.JPG', '.JPEG', '.PNG']:
                candidate = image_base / f"{img_id}{ext}"
                if candidate.exists():
                    img_path = candidate
                    break
        else:
            continue

        if img_path and img_path.exists():
            class_images[cls].append((str(idx), img_path))
        else:
            missing_images.append(str(img_path) if img_path else str(row.get(id_column, idx)))

    # 미매핑 형태 출력
    if unmapped_types:
        print(f"\n매핑되지 않은 형태 유형: {unmapped_types}")
        print("TYPE_MAPPING에 추가가 필요할 수 있습니다.")

    if missing_images and len(missing_images) <= 10:
        print(f"\n누락된 이미지: {missing_images}")
    elif missing_images:
        print(f"\n누락된 이미지: {len(missing_images)}개")

    # 클래스별 통계 및 데이터 분할
    print("\n클래스별 분포:")
    total_train, total_val = 0, 0

    for cls, images in class_images.items():
        if not images:
            print(f"  {cls}: 0개 (이미지 없음)")
            continue

        random.shuffle(images)
        split_idx = int(len(images) * train_ratio)
        train_images = images[:split_idx]
        val_images = images[split_idx:]

        # 이미지 복사
        for idx, img_path in train_images:
            dest = output_path / 'train' / cls / f"{idx}_{img_path.name}"
            shutil.copy2(img_path, dest)

        for idx, img_path in val_images:
            dest = output_path / 'val' / cls / f"{idx}_{img_path.name}"
            shutil.copy2(img_path, dest)

        print(f"  {cls}: train={len(train_images)}, val={len(val_images)}")
        total_train += len(train_images)
        total_val += len(val_images)

    print(f"\n총계: train={total_train}, val={total_val}")
    print(f"데이터셋 저장 완료: {output_path}")


def create_sample_metadata():
    """샘플 메타데이터 CSV 생성 (테스트용)"""
    sample_data = {
        '국소ID': ['LOC001', 'LOC002', 'LOC003', 'LOC004', 'LOC005', 'LOC006', 'LOC007', 'LOC008', 'LOC009'],
        '국소명': ['서울역북측', '강남역앞', '홍대입구', '명동역', '여의도공원', '잠실역', '신촌역', '영등포역', '용산역'],
        '형태': [
            '간이폴, 분산폴 및 비기준 설치대',
            '강관주',
            '복합형',
            '옥내, 터널, 지하 등',
            '원폴(건물)',
            '철탑(건물)',
            '철탑(지면)',
            '통신주',
            '프레임'
        ],
        '이미지경로': ['LOC001.jpg', 'LOC002.jpg', 'LOC003.jpg', 'LOC004.jpg', 'LOC005.jpg', 'LOC006.jpg', 'LOC007.jpg', 'LOC008.jpg', 'LOC009.jpg']
    }
    df = pd.DataFrame(sample_data)
    df.to_csv('sample_metadata.csv', index=False, encoding='utf-8-sig')
    print("샘플 메타데이터 생성: sample_metadata.csv")


def main():
    parser = argparse.ArgumentParser(description='데이터셋 준비 도구')
    subparsers = parser.add_subparsers(dest='command', help='명령어')

    # prepare 명령어
    prepare_parser = subparsers.add_parser('prepare', help='데이터셋 준비')
    prepare_parser.add_argument('--metadata', type=str, required=True,
                                help='메타데이터 파일 경로 (CSV/Excel)')
    prepare_parser.add_argument('--images', type=str, required=True,
                                help='이미지 디렉토리 경로')
    prepare_parser.add_argument('--output', type=str, default='data/processed',
                                help='출력 디렉토리 (기본: data/processed)')
    prepare_parser.add_argument('--type-col', type=str, default='형태',
                                help='형태 컬럼명 (기본: 형태)')
    prepare_parser.add_argument('--image-col', type=str, default='이미지경로',
                                help='이미지경로 컬럼명 (기본: 이미지경로)')
    prepare_parser.add_argument('--id-col', type=str, default='국소ID',
                                help='ID 컬럼명 (기본: 국소ID)')
    prepare_parser.add_argument('--train-ratio', type=float, default=0.8,
                                help='학습 데이터 비율 (기본: 0.8)')
    prepare_parser.add_argument('--seed', type=int, default=42,
                                help='랜덤 시드 (기본: 42)')

    # sample 명령어
    sample_parser = subparsers.add_parser('sample', help='샘플 메타데이터 생성')

    args = parser.parse_args()

    if args.command == 'prepare':
        prepare_classification_dataset(
            metadata_path=args.metadata,
            image_dir=args.images,
            output_dir=args.output,
            type_column=args.type_col,
            image_column=args.image_col,
            id_column=args.id_col,
            train_ratio=args.train_ratio,
            seed=args.seed
        )
    elif args.command == 'sample':
        create_sample_metadata()
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
