"""
철탑/안테나 분류 모델 학습 스크립트
YOLOv8 Classification 모델 사용
"""

import os
import yaml
import argparse
from pathlib import Path
from ultralytics import YOLO


def load_config(config_path: str) -> dict:
    """YAML 설정 파일 로드"""
    with open(config_path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def train(args):
    """모델 학습 실행"""

    # 설정 로드
    config = load_config(args.config)
    dataset_config = load_config(args.dataset)

    # 모델 초기화
    model_name = config.get('model', 'yolov8n-cls.pt')
    model = YOLO(model_name)

    print("=" * 50)
    print("철탑/안테나 분류 모델 학습 시작")
    print("=" * 50)
    print(f"모델: {model_name}")
    print(f"클래스: {dataset_config['names']}")
    print(f"에폭: {config.get('epochs', 100)}")
    print(f"배치 크기: {config.get('batch', 16)}")
    print("=" * 50)

    # 데이터 경로 설정
    data_path = Path(args.data) if args.data else Path(dataset_config['path'])

    # 학습 실행
    results = model.train(
        data=str(data_path),
        epochs=config.get('epochs', 100),
        batch=config.get('batch', 16),
        imgsz=config.get('imgsz', 224),
        patience=config.get('patience', 20),
        lr0=config.get('lr0', 0.01),
        lrf=config.get('lrf', 0.01),
        momentum=config.get('momentum', 0.937),
        weight_decay=config.get('weight_decay', 0.0005),
        warmup_epochs=config.get('warmup_epochs', 3.0),
        warmup_momentum=config.get('warmup_momentum', 0.8),
        hsv_h=config.get('hsv_h', 0.015),
        hsv_s=config.get('hsv_s', 0.7),
        hsv_v=config.get('hsv_v', 0.4),
        degrees=config.get('degrees', 0.0),
        translate=config.get('translate', 0.1),
        scale=config.get('scale', 0.5),
        shear=config.get('shear', 0.0),
        perspective=config.get('perspective', 0.0),
        flipud=config.get('flipud', 0.0),
        fliplr=config.get('fliplr', 0.5),
        workers=config.get('workers', 8),
        device=config.get('device', 0),
        project=config.get('project', 'runs/classify'),
        name=config.get('name', 'tower_classifier'),
        exist_ok=config.get('exist_ok', False),
        pretrained=config.get('pretrained', True),
        optimizer=config.get('optimizer', 'auto'),
        verbose=config.get('verbose', True),
        seed=config.get('seed', 42),
        deterministic=config.get('deterministic', True),
    )

    print("\n" + "=" * 50)
    print("학습 완료!")
    print(f"결과 저장 위치: {results.save_dir}")
    print("=" * 50)

    return results


def main():
    parser = argparse.ArgumentParser(description='철탑/안테나 분류 모델 학습')
    parser.add_argument('--config', type=str, default='configs/train_config.yaml',
                        help='학습 설정 파일 경로')
    parser.add_argument('--dataset', type=str, default='configs/dataset.yaml',
                        help='데이터셋 설정 파일 경로')
    parser.add_argument('--data', type=str, default=None,
                        help='데이터 경로 (설정 파일 대신 직접 지정)')
    parser.add_argument('--resume', type=str, default=None,
                        help='학습 재개할 체크포인트 경로')

    args = parser.parse_args()

    # 학습 재개
    if args.resume:
        model = YOLO(args.resume)
        results = model.train(resume=True)
    else:
        results = train(args)

    return results


if __name__ == '__main__':
    main()
