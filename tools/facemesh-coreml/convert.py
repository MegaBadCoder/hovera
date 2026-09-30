"""Переводит сеть точек лица MediaPipe (face_landmarks_detector.tflite из face_landmarker.task) в CoreML.

Использование: python convert.py <face_landmarks_detector.tflite> <FaceLandmarks.mlpackage>

Нужны torch, coremltools и tflite. Вход модели — картинка 256×256 RGB (яркость делится на 255),
выходы: landmarks — 478 точек × (x, y, z) в пикселях входа, presence — логит наличия лица.
Сеть собирается в PyTorch по графу и весам файла (tflite_to_torch.py), расчёт в float32.
"""
import sys

import coremltools as ct
import torch

from tflite_to_torch import TFLiteNet


class FaceLandmarks(torch.nn.Module):
    def __init__(self, path):
        super().__init__()
        self.net = TFLiteNet(path).eval()

    def forward(self, image):
        landmarks, presence, _ = self.net(image.permute(0, 2, 3, 1))
        return landmarks.reshape(1, 1434), presence.reshape(1, 1)


def main(source, target):
    traced = torch.jit.trace(FaceLandmarks(source).eval(), torch.rand(1, 3, 256, 256))
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 256, 256), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="landmarks"), ct.TensorType(name="presence")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
    )
    model.short_description = "MediaPipe face landmarks: 478 points from a 256x256 face crop. Converted from face_landmarks_detector.tflite (Apache 2.0)."
    model.save(target)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
