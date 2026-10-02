import math
import sys

import numpy as np
import tflite
import torch
import torch.nn.functional as F

OPS = {v: k for k, v in tflite.BuiltinOperator.__dict__.items() if not k.startswith("_")}
TYPES = {0: np.float32, 1: np.float16, 2: np.int32, 3: np.uint8, 4: np.int64, 9: np.int8}


def activation(x, code):
    if code == 0:
        return x
    if code == 1:
        return F.relu(x)
    if code == 3:
        return torch.clamp(x, 0, 6)
    raise NotImplementedError(f"activation {code}")


def same_pad(size, kernel, stride, dilation=1):
    effective = (kernel - 1) * dilation + 1
    out = math.ceil(size / stride)
    total = max((out - 1) * stride + effective - size, 0)
    return total // 2, total - total // 2


class TFLiteNet(torch.nn.Module):
    def __init__(self, path):
        super().__init__()
        buf = open(path, "rb").read()
        self.model = tflite.Model.GetRootAsModel(buf, 0)
        g = self.model.Subgraphs(0)
        self.graph = g
        self.consts = {}
        for i in range(g.TensorsLength()):
            t = g.Tensors(i)
            b = self.model.Buffers(t.Buffer())
            if b.DataLength() > 0:
                data = np.frombuffer(b.DataAsNumpy().tobytes(), dtype=TYPES[t.Type()]).reshape(t.ShapeAsNumpy() if t.ShapeLength() else ())
                self.consts[i] = data
        self.ops = []
        for i in range(g.OperatorsLength()):
            op = g.Operators(i)
            code = self.model.OperatorCodes(op.OpcodeIndex())
            name = OPS[max(code.BuiltinCode(), code.DeprecatedBuiltinCode())]
            self.ops.append((name, op.InputsAsNumpy().tolist(), op.OutputsAsNumpy().tolist(), op))
        self.params = torch.nn.ParameterDict()
        self.input_index = g.Inputs(0)
        self.output_indices = [g.Outputs(i) for i in range(g.OutputsLength())]
        self.float_consts = {}
        for name, ins, outs, op in self.ops:
            if name == "DEQUANTIZE":
                self.float_consts[outs[0]] = self.consts[ins[0]].astype(np.float32)
        for k, v in self.consts.items():
            if v.dtype == np.float32:
                self.float_consts[k] = v
        self.weights = {}
        for name, ins, outs, op in self.ops:
            if name == "CONV_2D":
                w = self.float_consts[ins[1]].transpose(0, 3, 1, 2)
                self._store(ins[1], w)
                if len(ins) > 2 and ins[2] >= 0:
                    self._store(ins[2], self.float_consts[ins[2]])
            elif name == "DEPTHWISE_CONV_2D":
                w = self.float_consts[ins[1]].transpose(3, 0, 1, 2)
                self._store(ins[1], w)
                if len(ins) > 2 and ins[2] >= 0:
                    self._store(ins[2], self.float_consts[ins[2]])
            elif name == "PRELU":
                self._store(ins[1], self.float_consts[ins[1]].reshape(-1))
            elif name == "ADD":
                for j in ins:
                    if j in self.float_consts:
                        self._store(j, self.float_consts[j])

    def _store(self, index, array):
        key = f"t{index}"
        if key not in self.params:
            self.params[key] = torch.nn.Parameter(torch.from_numpy(np.ascontiguousarray(array)), requires_grad=False)
        self.weights[index] = key

    def w(self, index):
        return self.params[self.weights[index]]

    def forward(self, x):
        values = {self.input_index: x.permute(0, 3, 1, 2)}
        for name, ins, outs, op in self.ops:
            if name == "DEQUANTIZE":
                continue
            if name == "CONV_2D":
                o = tflite.Conv2DOptions()
                t = op.BuiltinOptions()
                o.Init(t.Bytes, t.Pos)
                y = values[ins[0]]
                weight = self.w(ins[1])
                kh, kw = weight.shape[2], weight.shape[3]
                sh, sw = o.StrideH(), o.StrideW()
                dh, dw = o.DilationHFactor(), o.DilationWFactor()
                if o.Padding() == tflite.Padding.SAME:
                    ph = same_pad(y.shape[2], kh, sh, dh)
                    pw = same_pad(y.shape[3], kw, sw, dw)
                    y = F.pad(y, (pw[0], pw[1], ph[0], ph[1]))
                bias = self.w(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
                y = F.conv2d(y, weight, bias, stride=(sh, sw), dilation=(dh, dw))
                values[outs[0]] = activation(y, o.FusedActivationFunction())
            elif name == "DEPTHWISE_CONV_2D":
                o = tflite.DepthwiseConv2DOptions()
                t = op.BuiltinOptions()
                o.Init(t.Bytes, t.Pos)
                y = values[ins[0]]
                weight = self.w(ins[1])
                kh, kw = weight.shape[2], weight.shape[3]
                sh, sw = o.StrideH(), o.StrideW()
                dh, dw = o.DilationHFactor(), o.DilationWFactor()
                if o.Padding() == tflite.Padding.SAME:
                    ph = same_pad(y.shape[2], kh, sh, dh)
                    pw = same_pad(y.shape[3], kw, sw, dw)
                    y = F.pad(y, (pw[0], pw[1], ph[0], ph[1]))
                bias = self.w(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
                y = F.conv2d(y, weight, bias, stride=(sh, sw), dilation=(dh, dw), groups=y.shape[1])
                values[outs[0]] = activation(y, o.FusedActivationFunction())
            elif name == "PRELU":
                y = values[ins[0]]
                alpha = self.w(ins[1]).reshape(1, -1, 1, 1)
                values[outs[0]] = torch.clamp(y, min=0) + alpha * torch.clamp(y, max=0)
            elif name == "ADD":
                o = tflite.AddOptions()
                t = op.BuiltinOptions()
                o.Init(t.Bytes, t.Pos)
                a = values[ins[0]] if ins[0] in values else self.w(ins[0])
                b = values[ins[1]] if ins[1] in values else self.w(ins[1])
                values[outs[0]] = activation(a + b, o.FusedActivationFunction())
            elif name == "MAX_POOL_2D":
                o = tflite.Pool2DOptions()
                t = op.BuiltinOptions()
                o.Init(t.Bytes, t.Pos)
                y = values[ins[0]]
                kh, kw, sh, sw = o.FilterHeight(), o.FilterWidth(), o.StrideH(), o.StrideW()
                if o.Padding() == tflite.Padding.SAME:
                    ph = same_pad(y.shape[2], kh, sh)
                    pw = same_pad(y.shape[3], kw, sw)
                    y = F.pad(y, (pw[0], pw[1], ph[0], ph[1]), value=-1e30)
                values[outs[0]] = F.max_pool2d(y, (kh, kw), (sh, sw))
            elif name == "PAD":
                pads = self.consts[ins[1]].reshape(4, 2)
                y = values[ins[0]]
                values[outs[0]] = F.pad(y, (int(pads[2, 0]), int(pads[2, 1]), int(pads[1, 0]), int(pads[1, 1]),
                                            int(pads[3, 0]), int(pads[3, 1])))
            elif name == "LOGISTIC":
                values[outs[0]] = torch.sigmoid(values[ins[0]])
            elif name == "RESHAPE":
                y = values[ins[0]]
                shape = self.graph.Tensors(outs[0]).ShapeAsNumpy().tolist()
                values[outs[0]] = y.permute(0, 2, 3, 1).reshape(shape)
            else:
                raise NotImplementedError(name)
        result = []
        for index in self.output_indices:
            y = values[index]
            if y.dim() == 4:
                y = y.permute(0, 2, 3, 1)
            result.append(y)
        return tuple(result)


if __name__ == "__main__":
    net = TFLiteNet(sys.argv[1]).eval()
    x = torch.rand(1, 256, 256, 3)
    with torch.no_grad():
        print([o.shape for o in net(x)])
