import 'dart:typed_data';

/// The first plaintext byte of every CHWP datagram ('C' of "CHWP").
///
/// The receiver recovers the random seed from it: `seed = data[0] ^ 0x43`.
const int _knownFirstByte = 0x43;

int _rotl2(int b) => ((b << 2) | (b >> 6)) & 0xff;

int _nextKey(int plain, int key, int index) => _rotl2((plain + key + index + 0x93) & 0xff);

/// Scrambles a plaintext CHWP datagram with a rolling byte key.
///
/// MagicQ picks a random [seed] per datagram; any value 0..255 works.
Uint8List scramble(List<int> plain, int seed) {
  final out = Uint8List(plain.length);
  var key = seed & 0xff;
  for (var i = 0; i < plain.length; i++) {
    out[i] = plain[i] ^ key;
    key = _nextKey(plain[i], key, i);
  }
  return out;
}

/// Reverses [scramble]. The seed is derived from the first byte.
Uint8List unscramble(List<int> data) {
  final out = Uint8List(data.length);
  if (data.isEmpty) return out;
  var key = data[0] ^ _knownFirstByte;
  for (var i = 0; i < data.length; i++) {
    final plain = data[i] ^ key;
    out[i] = plain;
    key = _nextKey(plain, key, i);
  }
  return out;
}
