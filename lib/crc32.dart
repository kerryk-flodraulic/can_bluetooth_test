class CRC32 {
  int _reverse8(int value) {
    value = (value & 0xf0) >> 4 | (value & 0x0f) << 4;
    value = (value & 0xcc) >> 2 | (value & 0x33) << 2;
    value = (value & 0xaa) >> 1 | (value & 0x55) << 1;
    return value;
  }

  int _reverse32(int value) {
    value = (value & 0xffff0000) >> 16 | (value & 0x0000ffff) << 16;
    value = (value & 0xff00ff00) >> 8 | (value & 0x00ff00ff) << 8;
    value = (value & 0xf0f0f0f0) >> 4 | (value & 0x0f0f0f0f) << 4;
    value = (value & 0xcccccccc) >> 2 | (value & 0x33333333) << 2;
    value = (value & 0xaaaaaaaa) >> 1 | (value & 0x55555555) << 1;
    return value;
  }

  int calculate(List<int> data) {
    const digits1 = 0;
    const digits2 = 24;
    var crc = 0xFFFFFFFF << digits1;
    for (var item in data) {
      item = _reverse8(item);
      crc ^= item << digits2;
      const expected = 0x80 << digits2;
      const fixed = 0x04C11DB7 << digits1;
      for (var i = 0; i < 8; i++) {
        final actual = crc & expected;
        if (actual == expected) {
          crc = (crc << 1) ^ fixed;
        } else {
          crc <<= 1;
        }
      }
    }
    crc >>= digits1;
    crc = _reverse32(crc);
    crc ^= 0xFFFFFFFF;
    crc &= 4294967295;
    return crc;
  }
}