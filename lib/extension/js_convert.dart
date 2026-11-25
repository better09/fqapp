import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asn1/asn1_parser.dart';
import 'package:pointycastle/asn1/primitives/asn1_integer.dart';
import 'package:pointycastle/asn1/primitives/asn1_sequence.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/asymmetric/pkcs1.dart';
import 'package:pointycastle/asymmetric/rsa.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/cfb.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/block/modes/ofb.dart';

/// `Convert` 的 Dart 侧：编码、摘要和解密，参数格式同 Venera（GPL-3.0）。
/// 失败时返回 null，让脚本自己判断，和 Venera 行为一致。
Object? jsConvert(Map<String, dynamic> data) {
  final type = '${data['type']}';
  final value = data['value'];
  final encode = data['isEncode'] == true;
  try {
    switch (type) {
      case 'utf8':
        return encode
            ? Uint8List.fromList(utf8.encode('$value'))
            : utf8.decode(_bytes(value), allowMalformed: true);
      case 'gbk':
        const codec = GbkCodec(allowInvalid: true);
        return encode
            ? Uint8List.fromList(codec.encode('$value'))
            : codec.decode(_bytes(value));
      case 'base64':
        return encode ? base64Encode(_bytes(value)) : base64Decode('$value');
      case 'md5':
        return Uint8List.fromList(md5.convert(_bytes(value)).bytes);
      case 'sha1':
        return Uint8List.fromList(sha1.convert(_bytes(value)).bytes);
      case 'sha256':
        return Uint8List.fromList(sha256.convert(_bytes(value)).bytes);
      case 'sha512':
        return Uint8List.fromList(sha512.convert(_bytes(value)).bytes);
      case 'hmac':
        final hmac = Hmac(_hash('${data['hash']}'), _bytes(data['key']));
        final digest = hmac.convert(_bytes(value));
        return data['isString'] == true
            ? digest.toString()
            : Uint8List.fromList(digest.bytes);
      case 'aes-ecb':
        return _blocks(
          ECBBlockCipher(AESEngine())
            ..init(encode, KeyParameter(_bytes(data['key']))),
          _bytes(value),
        );
      case 'aes-cbc':
        return _blocks(
          CBCBlockCipher(AESEngine())..init(encode, _withIv(data)),
          _bytes(value),
        );
      case 'aes-cfb':
        return _blocks(
          CFBBlockCipher(AESEngine(), data['blockSize'] as int)
            ..init(encode, _withIv(data)),
          _bytes(value),
        );
      case 'aes-ofb':
        return _blocks(
          OFBBlockCipher(AESEngine(), data['blockSize'] as int)
            ..init(encode, KeyParameter(_bytes(data['key']))),
          _bytes(value),
        );
      case 'rsa':
        if (encode) return null;
        final cipher = PKCS1Encoding(RSAEngine())
          ..init(
            false,
            PrivateKeyParameter<RSAPrivateKey>(
              _privateKey('${data['key']}'),
            ),
          );
        return _rsaBlocks(cipher, _bytes(value));
      default:
        return value;
    }
  } catch (_) {
    return null;
  }
}

/// `Random`：`type == 'double'` 给小数，否则取整。
num jsRandom(Object? min, Object? max, Object? type) {
  final low = min is num ? min : 0;
  final high = max is num ? max : 1;
  final value = low + (high - low) * math.Random().nextDouble();
  return type == 'double' ? value : value.toInt();
}

/// 随机 UUID（v4）。Venera 用 v1，脚本只把它当唯一标识用。
String jsUuid() {
  final random = math.Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Uint8List _bytes(Object? value) {
  if (value is Uint8List) return value;
  if (value is ByteBuffer) return value.asUint8List();
  if (value is List) return Uint8List.fromList(value.cast<int>());
  if (value is String) return Uint8List.fromList(utf8.encode(value));
  throw ArgumentError('不支持的二进制数据：${value.runtimeType}');
}

Hash _hash(String name) => switch (name) {
  'md5' => md5,
  'sha1' => sha1,
  'sha256' => sha256,
  'sha512' => sha512,
  _ => throw ArgumentError('Unsupported hash: $name'),
};

ParametersWithIV<KeyParameter> _withIv(Map<String, dynamic> data) =>
    ParametersWithIV(KeyParameter(_bytes(data['key'])), _bytes(data['iv']));

Uint8List _blocks(BlockCipher cipher, Uint8List input) {
  final output = Uint8List(input.length);
  var offset = 0;
  while (offset < input.length) {
    offset += cipher.processBlock(input, offset, output, offset);
  }
  return output;
}

RSAPrivateKey _privateKey(String encoded) {
  var parser = ASN1Parser(Uint8List.fromList(base64Decode(encoded)));
  final top = parser.nextObject() as ASN1Sequence;
  parser = ASN1Parser(top.elements![2].valueBytes!);
  final key = parser.nextObject() as ASN1Sequence;
  BigInt part(int index) => (key.elements![index] as ASN1Integer).integer!;
  return RSAPrivateKey(part(1), part(3), part(4), part(5));
}

Uint8List _rsaBlocks(AsymmetricBlockCipher cipher, Uint8List input) {
  final blocks =
      input.length ~/ cipher.inputBlockSize +
      (input.length % cipher.inputBlockSize == 0 ? 0 : 1);
  final output = Uint8List(blocks * cipher.outputBlockSize);
  var read = 0;
  var written = 0;
  while (read < input.length) {
    final size = math.min(cipher.inputBlockSize, input.length - read);
    written += cipher.processBlock(input, read, size, output, written);
    read += size;
  }
  return output.length == written ? output : output.sublist(0, written);
}
