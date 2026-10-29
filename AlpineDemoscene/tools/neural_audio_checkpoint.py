"""Read TensorFlow v2 checkpoint tensors without importing/executing its code.

Only the uncompressed SSTable records and DT_FLOAT tensors used by the pinned
MIDI-DDSP checkpoint are accepted. No pickle, TensorFlow, or custom ops are run.
"""
from pathlib import Path
import struct
import numpy as np


def varint(data, pos=0):
    value = 0
    for shift in range(0, 70, 7):
        b = data[pos]
        pos += 1
        value |= (b & 127) << shift
        if b < 128:
            return value, pos
    raise ValueError('invalid varint')


def proto(data):
    result = {}
    pos = 0
    while pos < len(data):
        tag, pos = varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, pos = varint(data, pos)
        elif wire == 2:
            size, pos = varint(data, pos)
            value, pos = data[pos:pos + size], pos + size
        elif wire == 5:
            value = struct.unpack_from('<I', data, pos)[0]
            pos += 4
        elif wire == 1:
            value = struct.unpack_from('<Q', data, pos)[0]
            pos += 8
        else:
            raise ValueError(f'unsupported protobuf wire {wire}')
        result.setdefault(field, []).append(value)
    return result


def block_entries(data):
    nrestart = struct.unpack_from('<I', data, len(data) - 4)[0]
    end = len(data) - 4 * (nrestart + 1)
    pos = 0
    previous = b''
    while pos < end:
        common, pos = varint(data, pos)
        extra, pos = varint(data, pos)
        nvalue, pos = varint(data, pos)
        key = previous[:common] + data[pos:pos + extra]
        pos += extra
        value = data[pos:pos + nvalue]
        pos += nvalue
        previous = key
        yield key, value
    if pos != end:
        raise ValueError('malformed table block')


def read_index(path):
    data = Path(path).read_bytes()
    if struct.unpack_from('<Q', data, len(data) - 8)[0] != 0xdb4775248b80fb57:
        raise ValueError('unexpected SSTable signature')
    pos = len(data) - 48
    _, pos = varint(data, pos)
    _, pos = varint(data, pos)
    idxoff, pos = varint(data, pos)
    idxsize, pos = varint(data, pos)

    def block(offset, size):
        if data[offset + size] != 0:
            raise ValueError('compressed SSTable block is unsupported')
        return data[offset:offset + size]

    entries = {}
    for _, handle in block_entries(block(idxoff, idxsize)):
        off, q = varint(handle)
        size, q = varint(handle, q)
        for key, value in block_entries(block(off, size)):
            if key:
                entries[key.decode('utf-8')] = proto(value)
    return entries


def tensors(prefix):
    index = read_index(str(prefix) + '.index')
    raw = Path(str(prefix) + '.data-00000-of-00001').read_bytes()
    result = {}
    for key, fields in index.items():
        if fields.get(1, [0])[0] != 1:  # DT_FLOAT only; ignore object graph bytes.
            continue
        shape = [proto(dim)[1][0] for dim in proto(fields[2][0]).get(2, [])]
        off, size = fields.get(4, [0])[0], fields[5][0]
        if fields.get(3, [0])[0] != 0 or off + size > len(raw):
            raise ValueError('invalid tensor extent')
        tensor = np.frombuffer(raw, dtype='<f4', count=size // 4, offset=off)
        if np.prod(shape, dtype=np.int64) != tensor.size:
            raise ValueError('tensor shape/size mismatch')
        result[key] = tensor.reshape(shape).copy()
    return result


if __name__ == '__main__':
    import sys
    for name, value in tensors(sys.argv[1]).items():
        print(name, value.shape)
