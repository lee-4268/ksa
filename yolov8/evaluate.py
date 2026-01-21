"""
모델 평가 스크립트
학습된 모델의 성능을 평가하고 리포트 생성
"""

import argparse
import json
from pathlib import Path
from typing import Dict, List
import numpy as np
from ultralytics import YOLO


# 클래스 한글 매핑 (9개 클래스)
CLASS_NAMES_KR = {
    'simple_pole': '간이폴, 분산폴 및 비기준 설치대',
    'steel_pipe': '강관주',
    'complex_type': '복합형',
    'indoor': '옥내, 터널, 지하 등',
    'single_pole_building': '원폴(건물)',
    'tower_building': '철탑(건물)',
    'tower_ground': '철탑(지면)',
    'telecom_pole': '통신주',
    'frame_mount': '프레임'
}


def evaluate_model(
    model_path: str,
    data_path: str,
    split: str = 'val',
    batch_size: int = 16,
    device: int = 0
) -> Dict:
    """
    모델 성능 평가

    Args:
        model_path: 학습된 모델 경로
        data_path: 데이터셋 경로 (train/val 포함)
        split: 평가할 데이터 분할 (train/val)
        batch_size: 배치 크기
        device: GPU 디바이스

    Returns:
        평가 결과 딕셔너리
    """
    # 모델 로드
    model = YOLO(model_path)

    print("=" * 60)
    print(f"모델 평가: {model_path}")
    print(f"데이터: {data_path}/{split}")
    print("=" * 60)

    # 검증 실행
    metrics = model.val(
        data=data_path,
        split=split,
        batch=batch_size,
        device=device,
        verbose=True
    )

    # 결과 추출
    results = {
        'model_path': str(model_path),
        'data_path': str(data_path),
        'split': split,
        'metrics': {
            'top1_accuracy': float(metrics.top1),
            'top5_accuracy': float(metrics.top5),
        }
    }

    return results


def print_evaluation_report(results: Dict):
    """평가 결과 리포트 출력"""
    print("\n" + "=" * 60)
    print("평가 결과 리포트")
    print("=" * 60)

    metrics = results['metrics']
    print(f"\nTop-1 정확도: {metrics['top1_accuracy']:.2%}")
    print(f"Top-5 정확도: {metrics['top5_accuracy']:.2%}")

    print("\n클래스 정보:")
    for eng, kr in CLASS_NAMES_KR.items():
        print(f"  - {eng}: {kr}")

    print("=" * 60)


def main():
    parser = argparse.ArgumentParser(description='모델 평가')
    parser.add_argument('--model', type=str, required=True,
                        help='학습된 모델 경로')
    parser.add_argument('--data', type=str, required=True,
                        help='데이터셋 경로')
    parser.add_argument('--split', type=str, default='val',
                        choices=['train', 'val'],
                        help='평가할 데이터 분할 (기본: val)')
    parser.add_argument('--batch-size', type=int, default=16,
                        help='배치 크기 (기본: 16)')
    parser.add_argument('--device', type=int, default=0,
                        help='GPU 디바이스 (기본: 0)')
    parser.add_argument('--output', type=str, default=None,
                        help='결과 저장 경로 (JSON)')

    args = parser.parse_args()

    # 평가 실행
    results = evaluate_model(
        model_path=args.model,
        data_path=args.data,
        split=args.split,
        batch_size=args.batch_size,
        device=args.device
    )

    # 리포트 출력
    print_evaluation_report(results)

    # 결과 저장
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(results, f, ensure_ascii=False, indent=2)
        print(f"\n결과 저장: {output_path}")


if __name__ == '__main__':
    main()
