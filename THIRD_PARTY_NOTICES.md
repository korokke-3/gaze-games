# Third-party notices

このリポジトリには、以下の第三者のソフトウェア・モデルから派生した部分が含まれます。

## WebEyeTrack (MIT License)
https://github.com/RedForestAI/WebEyeTrack

- `models/blazegaze_encoder.onnx`, `models/blazegaze_mlp.npz`: `python/webeyetrack/model_weights/blazegaze_mpiifacegaze.keras` を `tools/convert_blazegaze.py` で変換したもの
- `gazekit/wet.py`: `webeyetrack/webeyetrack.py`, `model_based.py`, `utilities.py`, `filter.py`, `demo/` の処理を移植したもの
- `tests/data/blazegaze_ref.npz`: 上記の元モデル (Keras) で計算した参照値

```
Copyright (c) 2025 (Eduardo Davalos, Yike Zhang, Amanda Goodwin, Gautam Biswas)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.```

## MediaPipe Face Landmarker (Apache License 2.0)
https://github.com/google-ai-edge/mediapipe

- `models/face_landmarker_v2_with_blendshapes.task`: Google MediaPipe のモデル (WebEyeTrack リポジトリに同梱されていたものと同一)。
  ライセンス全文: https://www.apache.org/licenses/LICENSE-2.0

## 論文
- E. Davalos et al., "WebEyeTrack: Scalable Eye-Tracking for the Browser via On-Device Few-Shot Personalization", arXiv:2508.19544 (2025)
