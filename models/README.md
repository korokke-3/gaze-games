# モデルファイル

| ファイル | 内容 | 出典・ライセンス |
|---|---|---|
| `blazegaze_encoder.onnx` | BlazeGaze の CNN エンコーダ (128x512x3 -> 512)。OpenCV DNN で実行 | WebEyeTrack の `python/webeyetrack/model_weights/blazegaze_mpiifacegaze.keras` (MIT License, (c) RedForestAI) を `tools/convert_blazegaze.py` で変換 |
| `blazegaze_mlp.npz` | BlazeGaze の視線 MLP (518 -> 16 -> 16 -> 2) の重み | 同上 |
| `face_landmarker_v2_with_blendshapes.task` | MediaPipe Face Landmarker | Google MediaPipe (Apache License 2.0)。WebEyeTrack リポジトリ同梱のものと同一 |

元モデルは MPIIFaceGaze で学習されたもの。
