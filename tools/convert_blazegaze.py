"""WebEyeTrack の BlazeGaze (Keras 3 形式 .keras) を、OpenCV DNN で読める ONNX と numpy の MLP 重みに変換する。

開発時に一度だけ実行する (実行時には TensorFlow も onnx も不要)。
    python tools/convert_blazegaze.py blazegaze_mpiifacegaze.keras models/

必要: h5py, onnx (protobuf の版が mediapipe と衝突するので、本体とは別の venv で実行すること)

元モデル: https://github.com/RedForestAI/WebEyeTrack (MIT License)
  python/webeyetrack/model_weights/blazegaze_mpiifacegaze.keras
構成: 目の画像 (128x512x3, 0..1) -> cnn_encoder (BlazeBlock) -> 512次元
      [512 | head_vector(3) | face_origin_3d(3)] -> Dense16-ReLU -> Dense16-ReLU -> Dense2 = 正規化 PoG
"""
import json
import os
import sys
import zipfile

import h5py
import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


def tf_same_pads(n, k, s):
    """TensorFlow の padding='same' と同じ (前, 後) のパディング量。ストライド2では後ろ側が多い。"""
    out = -(-n // s)
    total = max((out - 1) * s + k - n, 0)
    return total // 2, total - total // 2


def main(keras_path, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    z = zipfile.ZipFile(keras_path)
    cfg = json.loads(z.read("config.json"))
    tmp = os.path.join(out_dir, "_weights.h5")
    with open(tmp, "wb") as f:
        f.write(z.read("model.weights.h5"))
    h5 = h5py.File(tmp, "r")

    enc = [l for l in cfg["config"]["layers"] if l["config"].get("name") == "cnn_encoder"][0]
    W = h5["layers/functional/layers"]

    def inbound(l):
        names = []

        def rec(a):
            if isinstance(a, dict) and a.get("class_name") == "__keras_tensor__":
                names.append(a["config"]["keras_history"][0])
            elif isinstance(a, list):
                for x in a:
                    rec(x)
        for n in l.get("inbound_nodes") or []:
            rec(n.get("args", []))
        return names

    nodes, inits = [], []
    shapes = {}          # テンソル名 -> (C, H, W)   NCHW
    H0, W0 = 128, 512
    shapes["input_layer"] = (3, H0, W0)

    def add_init(name, arr):
        inits.append(numpy_helper.from_array(np.ascontiguousarray(arr.astype(np.float32)), name))

    for l in enc["config"]["layers"]:
        cls, c = l["class_name"], l["config"]
        name = c["name"]
        if cls == "InputLayer":
            continue
        src = inbound(l)
        C, Hh, Ww = shapes[src[0]]
        if cls in ("Conv2D", "DepthwiseConv2D"):
            k = c["kernel_size"][0]
            s = c["strides"][0]
            assert c["padding"] == "same"
            ph = tf_same_pads(Hh, k, s)
            pw = tf_same_pads(Ww, k, s)
            w = W[name]["vars/0"][()]
            b = W[name]["vars/1"][()]
            if cls == "Conv2D":
                wt = w.transpose(3, 2, 0, 1)            # (kh,kw,in,out) -> (out,in,kh,kw)
                group, Cout = 1, w.shape[3]
            else:
                wt = w.transpose(2, 3, 0, 1)            # (kh,kw,C,1) -> (C,1,kh,kw)
                group, Cout = C, C
            add_init(name + "_W", wt)
            add_init(name + "_B", b)
            act = c.get("activation", "linear")
            out = name if act == "linear" else name + "_pre"
            nodes.append(helper.make_node("Conv", [src[0], name + "_W", name + "_B"], [out], name=name,
                                          kernel_shape=[k, k], strides=[s, s], group=group,
                                          pads=[ph[0], pw[0], ph[1], pw[1]]))
            if act == "relu":
                nodes.append(helper.make_node("Relu", [out], [name], name=name + "_relu"))
            else:
                assert act == "linear", act
            shapes[name] = (Cout, -(-Hh // s), -(-Ww // s))
        elif cls == "Add":
            nodes.append(helper.make_node("Add", src, [name], name=name))
            shapes[name] = shapes[src[0]]
        elif cls == "Activation":
            assert c["activation"] == "relu"
            nodes.append(helper.make_node("Relu", src, [name], name=name))
            shapes[name] = shapes[src[0]]
        elif cls == "MaxPooling2D":
            assert c["padding"] == "valid" and c["pool_size"] == [2, 2]
            nodes.append(helper.make_node("MaxPool", src, [name], name=name, kernel_shape=[2, 2], strides=[2, 2]))
            shapes[name] = (C, Hh // 2, Ww // 2)
        elif cls == "BatchNormalization":
            v = W[name]["vars"]
            gamma, beta, mean, var = (v[str(i)][()] for i in range(4))
            for suf, arr in (("_g", gamma), ("_b", beta), ("_m", mean), ("_v", var)):
                add_init(name + suf, arr)
            nodes.append(helper.make_node("BatchNormalization", [src[0], name + "_g", name + "_b", name + "_m",
                                                                 name + "_v"], [name], name=name,
                                          epsilon=float(c["epsilon"])))
            shapes[name] = shapes[src[0]]
        elif cls == "Flatten":
            # Keras は channels_last (H,W,C の順) で平坦化する -> NCHW から NHWC に並べ替えてから Flatten
            nodes.append(helper.make_node("Transpose", src, [name + "_nhwc"], name=name + "_t", perm=[0, 2, 3, 1]))
            nodes.append(helper.make_node("Flatten", [name + "_nhwc"], ["embedding"], name=name, axis=1))
            shapes["embedding"] = (C * Hh * Ww,)
        else:
            raise ValueError("unsupported layer %s" % cls)

    emb_dim = shapes["embedding"][0]
    assert emb_dim == 512, emb_dim
    graph = helper.make_graph(nodes, "blazegaze_encoder",
                              [helper.make_tensor_value_info("input_layer", TensorProto.FLOAT, [1, 3, H0, W0])],
                              [helper.make_tensor_value_info("embedding", TensorProto.FLOAT, [1, emb_dim])],
                              inits)
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 11)], producer_name="gazekit")
    model.ir_version = 7    # OpenCV 4.5 系でも読める版
    onnx.checker.check_model(model)
    onnx.save(model, os.path.join(out_dir, "blazegaze_encoder.onnx"))

    M = h5["layers/functional_1/layers"]
    np.savez(os.path.join(out_dir, "blazegaze_mlp.npz"),
             W0=M["dense/vars/0"][()], b0=M["dense/vars/1"][()],
             W1=M["dense_1/vars/0"][()], b1=M["dense_1/vars/1"][()],
             W2=M["dense_2/vars/0"][()], b2=M["dense_2/vars/1"][()])
    h5.close()
    os.remove(tmp)
    print("saved: blazegaze_encoder.onnx (%d nodes), blazegaze_mlp.npz" % len(nodes))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
